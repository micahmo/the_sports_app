# Design notes

Hard-won findings that are not obvious from the code. Mostly about the stream
player, which fights a moving target.

## The stream player does not use the site's player

`StreamPlayerScreen` loads an `embed.st` embed page in a `WebView`, but it does
**not** let that page play the stream. Instead `_takeoverJs` waits for the page
to fetch its HLS playlist, then throws the page away and runs our own
`<video>` + [hls.js](https://github.com/video-dev/hls.js) against the same URL.

### Why

As of 2026-09-20, `embed.st` serves the WebView a working, signed HLS URL and
then its own player bootstrap gives up and replaces `document.body` with:

> Remove sandbox attributes on the iframe tag

The message is misleading — nothing is sandboxed, and it is painted by the
site's own obfuscated bundle (appended to `strmd.b-cdn.net/js/bundle-jw.js`,
with a WASM component at `strmd.b-cdn.net/js/wasm/lock.{js,wasm}`). The same
page plays fine in a desktop browser, so something about Android WebView trips
it. The bundle is LZString-packed behind a virtualised obfuscator and the exact
check was never isolated.

What matters is that **the gate happens after the playlist URL is handed over**,
so we do not need to defeat it — we just need to ignore the site's player.

### Things that were ruled out, so don't retry them

All tested against a live WebView over the Chrome DevTools Protocol (see
below), not guessed at:

| Theory | Test | Result |
| --- | --- | --- |
| `window.open()` returns `null` in WebView | shimmed to a stub, then to a real `iframe.contentWindow` | still blocked |
| User agent contains `wv` | `Network.setUserAgentOverride` to a clean Chrome UA | still blocked |
| Mixed content blocked by default | `setMixedContentMode(alwaysAllow)`, verified an http iframe then loaded | still blocked |
| Our `onNavigationRequest` aborting the page's `/ad.html` subframe | allowed non-main-frame navigation | still blocked |
| WebView fingerprint | spoofed `window.chrome`, `navigator.plugins`, `mimeTypes`, `pdfViewerEnabled`, `Notification`, `userAgentData` | still blocked |

The `ERR_ABORTED` you will see on `embed.st/ad.html` is a *symptom*, not a
cause — the page removes that iframe itself after 9s.

## The playlist is gated on Chrome's TLS handshake

The signed `lb*.strmd.st/secure/<token>/…/playlist.m3u8` returns **403** to
anything that isn't Chrome. Established 2026-09-24 by elimination: the exact
header set the browser sends (captured over CDP, including `sec-ch-ua`), from
the same PC, still got 403 from curl; there are no cookies and the server only
speaks HTTP/1.1. `curl_cffi` impersonating **Chrome or Edge gets 200**, Safari
gets 403 — so nginx is checking the TLS handshake fingerprint. It also wants
`Origin`/`Referer: https://embed.st`. A request from inside the embed page (a
real Chrome, correct origin) passes, which is why every player we have fetches
it from there.

The segments are *not* gated: they live on TikTok's image CDN as signed
`…~tplv-tiktokx-origin.image` URLs that anything can download. Each is a
**42-byte fake WebP header** (`RIFF…WEBPVP8L…EXIF`) followed by plain MPEG-TS;
hls.js scans past the junk, most native players don't. A 4-second segment
is ~3.6 MB (1080p60 H.264 + AAC).

## Hiding the notice

Two layers, both needed:

1. A Flutter `ColoredBox` over the `WebViewWidget` until the page reports back.
2. `hidePage()` in `_takeoverJs`, which injects `html{visibility:hidden}`.

Layer 1 alone is not enough: the WebView is a platform view, and the page leaks
through the Flutter overlay for roughly one frame. This was verified by taking
raw `adb shell screencap` frames and counting pure-red pixels in the top band of
the screen — with only layer 1, exactly one frame in ~14 showed the notice.

> Watch out when checking this: count red only in the **top** ~260 rows. Video
> content in the middle of the screen is full of red (e.g. Chiefs jerseys) and
> will give you false positives.

The cover lifts on the `<video>`'s own `playing` event, not when our player is
built. Between the two, Android's WebView paints its default poster (a huge grey
play button) for about a second; the video also gets a transparent 1x1 `poster`
so that placeholder never shows. If autoplay is refused, the cover still lifts
once frames have been buffered for ~5s. To check, `adb shell screenrecord` the
start of a stream and tile the frames with ffmpeg (`fps=4,tile=12x8`).

## Source coverage

Tested on one live NFL game, 2026-09-20:

| Source | Result |
| --- | --- |
| `admin`, `delta`, `foxtrot` | play at real time, 1080p where offered |
| `golf` | **not supported** — see below |
| `hotel` | found a playlist that never started; may just be a dead feed |

### Nested-iframe sources

`golf` nests the real player two cross-origin iframes deep
(`embed.st/embed/golf/…` → `rockystream.st/source/streamed1.php` →
`embed.st/embed/ingest/…`). `runJavaScript` only reaches the main frame, so the
takeover script cannot see that playlist. Note the red notice you see for `golf`
is rendered *inside* the inner frame, not the top document — checking
`document.body` for it there will tell you nothing.

**Golf plays (2026-09-30), on all three apps.** The inner page is an ordinary
embed.st player page, and opened directly (not framed) it requests its playlist
like any other source's; the notice only appears because it's framed. So for a
source marked `nested` in `shared/app_data.json`, the apps fetch the embed page,
follow its first cross-site `<iframe>` (the middle page, fetched with the embed
page as Referer), decode the inner address from its `atob("…")`, and play that
page instead: `StreamedApi.innerPlayerUrl` on phone/desktop (the player loads
it in place, `_openPage`), `playerPageUrl` in `streamlink.brs` on the Roku (the
server's Chrome opens it; the background link-refresher reuses it). The stream
keeps its golf embed URL everywhere else (quality, recents, fallback). If the
chain doesn't match, they fall back to the embed page, and `hasForeignPlayer()`
still reports `blocked` as before.

The earlier notes here said the inner pages were "gated too" and parked golf as
hard; that was a guess from the notice showing inside the frames, never tried.
Worth remembering: test the assumption before parking something as hard.

### Gotcha: innerText vs textContent

`pageGaveUp()` must use `textContent`, not `innerText`. We blank the page with
`visibility:hidden`, and `innerText` is layout-aware, so it returns an empty
string for hidden content and the notice is never detected.

## API notes

Checked 2026-09-20 against live data, which does not always match `/docs`.

### Undocumented but useful

- **`viewers` on every stream row** (`/api/stream/{source}/{id}`). Not in the
  published `Stream` interface, but present on 31/31 sampled rows. Parsed as
  nullable in case it disappears.
- **`/api/matches/live/popular-viewcount`** — normal match objects plus a
  match-level `viewers` total. Only returns the top few live matches, so most
  matches have no count. They are the biggest by a wide margin though: when
  measured, the lowest covered match had 342 viewers and the highest uncovered
  had 31. That gap is why sorting by it does not bury anything.
- **`/api/matches/featured`** — 12 curated matches, all `popular: true`, a
  subset of `/api/matches/all/popular`. Mixes live and upcoming (4 live, 8
  upcoming when sampled). Unused; would be the app's first upcoming view.

### Traps

- **`/api/matches/all-today` is not today.** It returns byte-identical ids to
  `/api/matches/all`; only 18 of its 99 rows were actually today. The
  client-side filter in `_applyTodayOnlyFilter` is more correct — don't "simplify"
  it to this endpoint.
- **The docs' source list is stale.** It names alpha, bravo, charlie, delta,
  echo, foxtrot, golf, hotel, intel and omits `admin`. Live data across 15
  sports / 99 matches only ever had **admin, delta, foxtrot, golf, hotel**.
  Descriptions for the absent ones are kept in `shared/app_data.json` because
  sources have come and gone before.
- **Source descriptions are not in the API at all** — they are scraped by hand
  from the watch pages, and they do change wording.
- **The "popular" toggle means popular *and live*** by construction:
  `_loadBySportFor` intersects the sport list with `/api/matches/live/popular`.
  `/api/matches/{sport}/popular` would be one request instead of two but
  includes upcoming matches, which is a different thing. Deliberate.

## Theming

Palette and the theme-mode preference live in `lib/src/theme.dart`. The dark
theme is a grey (`#22252A`), not black, and contrast was checked rather than
eyeballed: body text ~12:1 on the background, secondary text ~9:1, and every
accent at least 3:1 (most above 4.5:1) in *both* themes. `adaptiveColor` exists
because an accent that reads well on dark is usually too pale on light.

To re-check after changing a colour, sample the rendered pixels rather than
trusting the constants:

```bash
adb exec-out screencap > frame.bin   # raw RGBA, easy to sample in a script
```

### Spinners

A loading spinner that has the screen to itself sits in the screen's true
centre, on every app; titles, headers and status text fall around it, and never
move it. (Centred in the space under a title it looks low; centred together
with the text under it, it looks high when the text is there and jumps when it
isn't.) Phone and desktop use `ScreenSpinner`, which makes up for the app bar;
the Roku puts it at 960×540. On phone the Home spinner lands where the splash
icon was, so the hand-off doesn't jump. Spinners inside a panel (the Roku's
streams beside the list) centre in the panel.

### The splash screen cannot follow the in-app theme

`android/app/src/main/res/values{,-night}/` already give the launch screen a
light and dark colour, so it follows the **system** setting for free. It cannot
follow the in-app override: Android paints it from the manifest theme before
Flutter — and therefore SharedPreferences — exists. Someone running system-light
with the app forced to dark will see a light splash. This is why the colours in
`values/colors.xml` are kept in sync with `theme.dart` by hand; the only real
fix would be reading the pref in `MainActivity` natively, which still cannot
change the very first frame.

## Keeping the apps in sync

There are two code bases, Flutter (phone and desktop) and BrightScript (Roku),
so nothing can be shared as code. Two things keep them from drifting:

**Shared data.** Anything both apps need to agree on lives once, in
`shared/app_data.json`: sport display names (Soccer, Football) and icons, the
stream sources in ranked order with their descriptions, and the colours. After
editing it, run `python shared/generate.py`, which writes
`lib/src/generated/app_data.dart` and `roku/app/source/generated/app_data.brs`,
and commit all three. `roku/tools/make_assets.py` draws the Roku's sport icons
from the same icon names, looking their codepoints up in Flutter's own
`icons.dart`. The release workflow runs `generate.py --check` first and stops
if the generated files are stale. (Before this, three of the nine source
descriptions had quietly drifted apart.)

It's generated code rather than each app reading the JSON because a Flutter
release build strips unused icons from the icon font, which needs the icons to
be constants.

**The parity table.** When a user-visible change lands in one app, it lands in
the others or is added here as a deliberate gap.

| Feature | Android | Windows | Roku |
| --- | --- | --- | --- |
| Home: live counts, Most watched, all sports | yes | yes | yes |
| Live, Popular and each sport's games | yes | yes | yes |
| Favorite teams | yes | yes | no |
| Search and filters (today, popular, sport chips) | yes | yes | no: no text entry worth using on a remote |
| Games beside the chosen game's streams | no: games, then streams | yes (wide windows) | yes |
| Quiet background refresh | on returning to the app | every minute idle, and on returning | every minute idle, and back from a stream |
| Streams grouped by source, best first, described | yes | yes | yes |
| Measured quality on played streams' rows | yes | yes | yes |
| Which of a source's qualities plays | the best, never switched (they're separate feeds) | the best, never switched | the best, never switched |
| A stuck segment download | second copy after 4 s if nothing is arriving | same | second copy after 4 s |
| Title bar with the game and quality in the player | from the start until the quality is known, then tap, or the menu | from the start until the quality is known, then mouse movement, or the menu | from the start until the quality is known, then OK |
| Player menu button | shows and hides with the title bar | shows and hides with the title bar, fullscreen included; the pointer hides with it in fullscreen | no menu: the remote's buttons |
| Streams row in the player (this game's other streams, recent games) | Streams pill with the title bar; tap it; tap away or Back closes | Streams pill; click it; click away or Esc closes | Streams pill with the title bar; Down, then Left/Right, OK; Up or Back closes |
| No pause (live streams only; a pause would just fall behind live) | no pause control | no pause control | Play/Pause shows the title bar like the other buttons |
| A stream that fails for good | tries the next like it (HD for HD, SD for SD), then the other kind, then "unavailable" | same | same |
| Reconnecting by itself after a stall or outage | yes | yes | yes |
| A source's server dropping the stream mid-game | reload after 20 s (a visible restart) | reload after 20 s (a visible restart) | fresh link in the background, usually unnoticed; see "Servers that drop a stream" |
| First link doesn't answer | "unavailable" | "unavailable" | two more fresh sessions first |
| Picture-in-picture, now-playing notification | yes | no | no |
| Fullscreen, keyboard shortcuts, remembered window | no | yes | no |
| Light and dark themes | yes | yes | dark only |
| Version in Settings | yes | yes | yes |
| Updates | through Obtainium | checks at every start, installs itself and restarts | checks at start and hourly, says one is available; installing is up to the user |
| Asks before exiting on Back | no | no | yes: TV convention |
| Needs the Chrome stream server | no | no | yes (see Roku) |
| `golf` streams | play (inner page opened directly) | play | play |

## Windows

`webview_flutter` has no Windows implementation, so `lib/src/player/player_webview.dart`
wraps two backends behind one small interface: `webview_flutter` everywhere else,
WebView2 via `webview_windows` on Windows. The takeover script is shared; on
Windows a document-created script defines `window.AppPlayer.postMessage` on top of
WebView2's `chrome.webview.postMessage`, so the page side is identical.

Things that differ from Android and were each found the hard way:

- **The page's own player keeps running.** On Android it gives up (that is the
  sandbox notice); in WebView2 it loads jwplayer, Clappr, hls.js 1.6 and a P2P
  engine (`@swarmcloud/hls`) and starts streaming. Two consequences:
  - `window.Hls` is the page's P2P-patched copy. Building our player on it gave
    corrupt fragment timings (one fragment "lasted" 31,320s) and a live edge
    hours past the buffer, so nothing played. The takeover now always loads its
    own pinned hls.js and keeps a private reference (`OurHls`) — never use
    whatever `window.Hls` happens to be.
  - After we replace the page, its player keeps downloading into a detached
    `<video>`, doubling bandwidth. `jwplayer().remove()` stops it.
  - It also fetches the quality it picked (`high/mono.m3u8`) after the master
    playlist, and the takeover used to take the *last* playlist the page
    fetched, so desktop played whatever the page's player chose. It now takes
    the first, the master, and picks the best feed itself (see below).

- **Autoplay with sound is refused** unless the page itself was clicked, and the
  click lands on Flutter. The WebView2 environment is created with
  `--autoplay-policy=no-user-gesture-required`.
- **Keyboard focus.** Once the video is clicked, WebView2 holds keyboard focus
  and Flutter never sees keys, so the page forwards Esc/M/F as `key:<name>`
  messages.
- **Navigation can't be vetoed** from `webview_windows`; off-site navigations are
  undone by reloading the embed URL (as `onUrlChange` does on Android), and
  popups are denied outright.

### Playlists and segment downloads (phone and desktop)

**One quality, never switched (all apps).** A master playlist lists a
source's qualities, but on these sources they are **separate feeds**, not
renditions of one stream. Seen on admin streams (2026-09-30): "1080p" in 5 s
segments numbered from 83,350 on tiktokcdn with program-date-time tags, "540p"
in 3 s segments numbered from 2,367 on the site's own host, without them. Every
player assumes a source's qualities line up, so switching between these lands
on the wrong stretch: hls.js replayed the same few seconds over and over. That
was the phone's loop on a 1080p60 source, and 1.0.88 (which handed desktop the
master too) made desktop do it on every admin stream. So the takeover reads the
master itself and plays the best feed's own playlist (`bestFeed()`), as the Roku
always has (`pickMedia`). The cost is no stepping down on a weak connection;
the upside is that playback works. Don't hand hls.js a master playlist from
these sources again, and when checking playback, check that `currentTime`
keeps advancing, not just the quality label.

**Racing stuck downloads (phone and desktop).** hls.js fetches one segment at
a time, so one request the server sits on (seen: ~11 s for a 6 s segment) pauses
playback. The takeover wraps hls.js's own segment loader (`hedgedLoader`): a
download still running after 4 s that has received nothing new for a second
gets a second copy, and the first to finish is used, as on the Roku. A download
that is slow but still arriving is left alone, so on a slow phone connection it
doesn't split the bandwidth or spend more data. Tested (desktop, NFL Network)
by holding every third segment request for 12 s through the DevTools protocol:
each was noticed at 4.0 s, the second copy won within 0.2 s, and playback never
paused.

**Frame rate (phone and desktop, as the Roku).** Read from the video's own
PES timestamps in the first segment (`tsFps`, the same method as the Roku's
`tsinfo.brs`): the smallest step between frames, snapped to the nearest of 24,
25, 30, 50 and 60 within 10% (timestamps jitter: a 60 fps feed steps 1530,
1440, 1530 ticks of 90 kHz), and left off the label when near none. It's read
in `hedgedLoader`'s success callback because hls.js hands the segment to its
worker before `FRAG_LOADED`. Until 2026-09-30 the phone listened for
`FRAG_PARSING_DATA`, which hls.js 1.5 never sends, so every frame rate it
showed was the device's decoding speed ("1080p2" on a slow decoder, "70" after
a catch-up burst). Lesson: when two apps compute the same thing, use one
method, and check each actually produces values.

### Streams row and falling back (all apps)

Agreed with the user from mockups (2026-09-30). A tap, mouse movement or OK
shows the title bar, the menu (phone/desktop) and a small **Streams** pill at
bottom centre. The row opens only on a deliberate press: tapping or clicking the
pill, or Down on the Roku (opening it on hover, tried first on desktop, put a
big bar up by accident). It closes by tapping away from it (the page reports
taps as `pointer:down`), Back (the phone's gesture too, via `PopScope`), Esc on
desktop, or Up on the Roku; otherwise it goes when the title bar does (a
little longer while it's open). The menu button makes way for it. The title
bar and pill also come up over the loading, fallback and unavailable screens,
so another stream can be picked without waiting out a fallback.

- **THIS GAME** (left): the match's other streams, the same HD/SD as what's
  playing first, best sources first, none that failed this viewing.
  **RECENT** (right): other games played lately (`Recents`, one per game),
  kept while `/api/matches/live` lists them, or for 24/7 channels (no start
  time, never on the live list) while `/api/matches/all` does. The full list
  alone won't do: it keeps games for hours after they end (Browns-Steelers was
  still on it 12 h after kickoff, with no streams). On the Roku, Down lands on the first recent
  game, else the first of this game's streams (a start on the divider read as a
  stop you could never get back to).
- Cards are all one size with the same three slots (top row, name, details);
  details lead with quality ("720p60 · Admin 1"). The title bar's second line
  too: "1080p30 · 6.2 Mbps · Admin · Stream 1".
- Picking switches in place (the same player; `PlayerWebView.load` on
  phone/desktop, a fresh StreamTask on the Roku). Back still returns to the
  list, which then marks whichever of the game's streams played last.
- **Falling back:** a stream that fails for good (never starts, or the
  reconnects give up) hands over to the next one like it: HD for HD, SD for
  SD, best sources first, the same language (compared as the language itself:
  "English" matches "English - NBC"), never one already tried. The spinner
  says "Golf 1 (HD) stopped working / Trying Admin 1 (HD)…", then a short
  "Switched to Admin 1 (HD)" note takes the pill's place. When nothing like it
  is left, the other kind (an SD stream beats nothing when every HD one is down;
  user, 2026-09-30), and only then "unavailable".
- The numbers (cards per side, recents kept, the note's time) and the wording
  are in `shared/app_data.json` (`player`, `playerText`).

### Buffer gaps

Some feeds leave holes in the buffer (seen: 1–4s and 9–18s buffered, nothing in
between). Playback stalls at the hole, and `hls.liveSyncPosition` can point back
into the stale stretch, so "jump to live" replayed the same few seconds forever.
The watchdog now hops to the next buffered range after ~1s of stalling, and
only trusts `liveSyncPosition` when it lies inside the buffer. This applies to
Android too.

The same loop came back another way (2026-09, on a 1080p60 source on Android):
playback stuck at one spot with data buffered past it. hls.js nudges the
playhead three times, then raises a fatal media error; `recoverMediaError()`
reloads from where it was, so the same segment played again, over and over. And
the watchdog's jump to live could land *behind* the stuck spot. Now:

- Jumps to live only ever go forward; if live isn't ahead, the watchdog steps
  1 s past the stuck spot instead.
- Stuck again within 15 s of that, or a second fatal media error within 30 s of
  a recovery: the app reloads the stream (a fresh link, at live) instead.
- Playing on but well behind live (`hls.latency` more than 12 s past its target,
  and under 120 s so a feed with bad timestamps can't set it off): jump to live.
  This covers a short network blip that hls.js rides out by itself, and the
  app's jump to live on coming back from the background, which uses the same
  code.
- The takeover logs what it does about trouble (`[player] ...` in `adb logcat`):
  hls.js errors, stuck spots, catching up, and segments that took longer to
  fetch than to play.

### Debugging

Launch with `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=9223`
and `curl http://127.0.0.1:9223/json/list` gives a CDP target, like the Android
recipe below. `Runtime.queryObjects` on `Hls.prototype` finds every hls.js
instance in the page, including ones hidden in closures.

### Building

Flutter 3.35 can't build with Visual Studio 2026 (it asks CMake for the 2019
generator); 3.38+ can. If a build fails with "Does not match the generator used
previously", delete `build/windows`.

## Roku

A Roku can't run the embed page (no JS/WASM engine, no web view) and its TLS
stack is fixed, so it can't get or fetch the playlist itself — tested: 403 from
the device. What it *can* do, measured on an 85" Roku TV (OS 15.3):

- download a segment from TikTok's CDN in ~0.4–0.6 s and strip the fake header
  with `roByteArray.ReadFile(path, offset, length)` in ~25 ms;
- run its own HTTP server on a `roStreamSocket` and have its `Video` node play
  `http://127.0.0.1:<port>/…` from it;
- speak WebDriver (plain HTTP + JSON) with `roUrlTransfer`.

So the design is: a **Selenium standalone Chrome container** on the LAN
(`selenium/standalone-chrome`, template in micahmo/docker-templates) does the
browser part. The Roku app opens a WebDriver session, loads the embed page,
reads the playlist URL from `performance.getEntriesByType("resource")`, removes
the page's own player (`jwplayer().remove()`, or the server decodes and
downloads the whole stream for nothing), and from then on asks that page to
`fetch()` each playlist (~120 ms round trip). Its local proxy rewrites segment
URLs to itself, downloads them straight from TikTok, strips the header and
serves plain TS to the player. The video never passes through the server.

**Serve one rendition, never the master.** The page may hand over a master
playlist (1080p at 8 Mbps and 540p). Given the choice, Roku's player starts on
540p and stalls trying to switch up through the local proxy: one frame of
video, then paused/buffering cycles and black. The app picks the master's
highest-bandwidth rendition itself and serves only that media playlist. Which
one the page exposed first used to be a matter of timing, which is how this
showed up as a "regression".

A stream that isn't broadcasting still hands over a playlist URL, but the
playlist answers HTTP 200 with the body `Not found`. Check that a fetched
playlist starts with `#EXTM3U` before playing, and say the stream is
unavailable (as the phone app does) instead of letting the player fail with
"an unexpected problem".

Each stream's local server takes the first free port from 8888–8911: the
previous stream's server can still be finishing a request when the next
starts, and sharing a port hands the player the old stream.

Sessions: Home kills a Roku app outright (`EXIT_USER_NAV`) with no chance to
clean up, so the app remembers its session id in the registry and deletes it on
the next launch, and Selenium's idle session timeout reaps anything else.
Selenium also needs `browserName: chrome` in the capabilities to route a session.

Background refresh: every minute the screen on top reloads quietly, but only
after 10 s without input. `roDeviceInfo.TimeSinceLastKeypress()` counts only
the physical remote; keys from the Roku mobile app (ECP) don't reset it, so the
screens also record input themselves (`noteInput`) and the timer goes by the
more recent of the two.

Stream quality (resolution, frame rate, bitrate) is measured by the proxy:
bitrate from segment sizes over their `#EXTINF` lengths, resolution and frame
rate from the H.264 SPS and PES timestamps at the start of a segment
(`source/tsinfo.brs`), since the Video node reports height 0 and no frame rate.
Two things to keep:
- Read only the start of a segment. Walking a whole 6 MB segment in BrightScript
  blocks the proxy's thread long enough for the player to run dry.
- Don't touch the Video's content during playback, not even `content.title`:
  doing so made the next segment take ~11 s and the stream stall, every time.
  That's why the quality isn't shown in the player's own title bar.

Reconnects overlap: the old stream task can still be stuck in a slow fetch when
the new one starts. So a task closes only its own browser session (never "the
remembered one", except the first stream of an app run tidying up after a
crash), a failed new link keeps the old one, and `quitRequested()` reads
the `quit` field instead of draining the message port, which also carries the
stream server's socket events. Getting any of these wrong crashed the app on
2026-09-24 whenever a reconnect met a slow fetch. (With the debug console
attached, a crash freezes the app in the debugger rather than exiting it.)

Source reliability differs: on 2026-09-24, admin's 720p segments (TikTok's CDN)
had 2 of 1,794 downloads over 5 s; foxtrot/hotel's 1080p segments (the site's
own servers) had 12 of 891, each ~11 s against 6 s segments, enough to stall.

So the proxy downloads segments in the background: the newest few as soon as a
playlist lists them, and a second copy of any download still running after 4 s,
serving whichever copy finishes first (those slow downloads look like a request
stuck on the server). Tested by pointing every 4th segment's first copy at an
unreachable address: each cost ~4.4 s instead of stalling, and playback never
buffered. Prefetch alone gains little, because the player asks for a segment
almost as soon as the playlist lists it; hiding the newest segment from the
player would buy a whole segment of cushion, at ~6 s more delay behind live.

A download that fails outright is tried again after 0.5, 1, 2 and 4 s, with
the CDN's error code logged. The tries used to go straight after one another,
and on 2026-10-04 four admin segments failed all three within a tenth of a
second (other segments loading fine meanwhile, so most likely not yet on the
CDN just after being listed); the player skipped the one it needed and froze.
Spaced out, the tries span ~7.5 s, within the ~12 s the player has in hand.

Things that were tried and didn't pan out: headers/HTTP-2 tricks for the
playlist (it's the TLS fingerprint), and a server relay that re-serves the video
(works, but unnecessary once the Roku can unwrap segments itself).

### Servers that drop a stream

The `lb*.strmd.st` sources (delta, foxtrot, hotel) can lose a stream on one
server while others carry on: on 2026-09-25 delta's playlist on whichever
server we had started answering 404 every 30 s to 6 min, and a new link often
came back already dead. What we measured with a browser session:
- Each fresh session gets a new token, often on another server (lb5, lb8, lb11,
  lb16...). The token isn't tied to the session.
- Reloading the page in the same session gets a new token but usually the same
  server, cookies and storage or not (there are none). That's why the old
  in-session refresh kept handing back the dead link.
- Every server lists the same segments at the same media sequence, so the
  player can switch links mid-stream without a gap.
- The page gets its link from `embed.st/fetch`, decoded by the WASM lock, so a
  new link means loading the page; we can't call that ourselves.

So on the Roku, when the playlist stops answering, `MintTask` opens fresh
sessions in the background (up to three, as the first link may be dead too)
while the proxy keeps giving the player the last good playlist; the player
plays on through its buffer and carries on from the new link. The full
reconnect stays as the backstop. At start, a link that doesn't answer gets two
more fresh sessions before the stream is called unavailable.

Not on the phone or desktop yet (parked, 2026-09-25): they'd load the page in
a hidden same-site iframe inside the player page (tested: its link can be read,
~1 s) and switch hls.js over with a playlist loader that swaps the dead URL for
the new one. The iframe tended to land on the same server as the page, so it
would need retries too.

### Short playlists and high bitrates

Some sources list only their last 4 segments (12 s). On 2026-10-04 an admin
stream at 12.5 Mbps froze the Roku's picture for ~4 s once a minute, like
clockwork, with no spinner: the player's position jumped ~4 s ahead and then
held. The segments were fine (continuous timestamps, fast downloads) and the
player was ~24 s behind live with its buffer ~94% full. Of 60 segments
published in 3 minutes it asked for 56: its buffer fills by size before it
holds enough seconds, so it asks for its next segment late, finds it gone from
the list and skips. (At 7 Mbps the night before, no skips.)

The proxy now offers the player the last 45 s of segments (`longerWindow` in
StreamTask): the source's CDN still serves a segment minutes after it leaves
the list (checked 5 min later). It passes through playlists with
discontinuities or an end. The player gets the proxy's own numbering, one after
another: at first the list started over whenever the source's numbering
jumped, and a slow playlist answer could skip a number, so the list emptied to
the source's 4, the player (~20 s behind) fell off it and skipped, then again a
minute later (twice on 2026-10-04, ~20 s after a slow answer each time; the
source's timestamps were continuous). Now a jump only costs the segments
actually missed (logged as "missed N segment(s)"), and the list starts over
only if the numbering restarts (by 100 or more).
No freezes after. Phone and desktop don't need it: hls.js limits its buffer by
time (30 s) before size (60 MB), so it fetches each segment as soon as it's
listed.

The same window gives a flaky stream a cushion, with no delay for healthy
ones. After a hang the player carries on from where it paused, behind live by
the hang, and the segments it hasn't played stay listed, so the next hang of
that length plays through. (The same source that day also had 17 s playlist
hangs that hit a fresh link too, so getting a new link sooner wouldn't help.)
A reconnect (a stall past 20 s) would start at the live edge and lose the
cushion, so after one the player pauses the new stream for 12 s behind a black
cover and the spinner (`holdBack` in PlayerScreen) while the source publishes
on, then resumes 12 s further behind live with those segments in hand
(tested: resumed ~24 s behind, every segment ready before it was asked for).
Switching streams starts without it. Phone and desktop can't hold a cushion
beyond what the source lists (~12 s): hls.js jumps back to live once its next
segment is gone.

None of that helped while the proxy fetched the playlist and waited: a 17 s
playlist request held up the whole proxy, so the player couldn't get even the
segments it had in hand, and spun after ~15 s however far behind live it was.
The playlist is now fetched in the background like the segments (`askPlaylist`
in StreamTask): the player gets the source's newest if it comes within 1.5 s
(it takes ~100 ms), else the last good one, and segments keep flowing. Tested
with a build that held one playlist fetch in ten for 9 s: segments were served
all through each hold, no buffering. Phone and desktop already fetch playlists
in the background (hls.js).

## Debugging recipe

`AndroidWebViewController.enableDebugging(true)` is not enabled in the committed
code — add it temporarily. Then:

```bash
adb shell cat /proc/net/unix | grep -o "webview_devtools_remote_[0-9]*"
adb forward tcp:9333 localabstract:webview_devtools_remote_<pid>
curl -s http://localhost:9333/json/list
```

That gives a CDP WebSocket URL. `Page.addScriptToEvaluateOnNewDocument` runs
code *before* any page script, which is strictly more than the app can do via
`onPageStarted` — useful for proving whether an injected fix could ever work
before spending a build cycle on it. `Debugger.scriptParsed` +
`Debugger.getScriptSource` will dump `eval`'d code that hooking `eval` and
`Function` misses.

`AndroidWebViewController.setOnConsoleMessage` forwards page console output to
`debugPrint`, which shows up in `adb logcat`.

## Emulator caveats

The x86 emulator decodes video in software and will rebuffer on streams that are
fine on a real device. Judge playback by whether `currentTime` advances at
roughly wall-clock rate over ~10s, not by how it looks.
