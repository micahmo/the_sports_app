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

So when no playlist turns up but the page has a large cross-origin iframe, the
takeover script reports `blocked` and we show our own "stream unavailable"
message with the page still blanked. We cannot read or hide the inner frame, and
for this site those inner pages are gated too and render the same notice — so
revealing the page just shows the user the notice. If a nested source ever does
work, `hasForeignPlayer()` in `_takeoverJs` is the branch to relax.

Supporting `golf` properly would mean detecting the inner player and navigating
the WebView to it directly (two hops), which also needs the navigation
allow-list in `_isAllowedDestination` relaxed.

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
  Descriptions for the absent ones are kept in `sourceSubtitles` because sources
  have come and gone before.
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

### The splash screen cannot follow the in-app theme

`android/app/src/main/res/values{,-night}/` already give the launch screen a
light and dark colour, so it follows the **system** setting for free. It cannot
follow the in-app override: Android paints it from the manifest theme before
Flutter — and therefore SharedPreferences — exists. Someone running system-light
with the app forced to dark will see a light splash. This is why the colours in
`values/colors.xml` are kept in sync with `theme.dart` by hand; the only real
fix would be reading the pref in `MainActivity` natively, which still cannot
change the very first frame.

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
- **Autoplay with sound is refused** unless the page itself was clicked, and the
  click lands on Flutter. The WebView2 environment is created with
  `--autoplay-policy=no-user-gesture-required`.
- **Keyboard focus.** Once the video is clicked, WebView2 holds keyboard focus
  and Flutter never sees keys, so the page forwards Esc/M/F as `key:<name>`
  messages.
- **Navigation can't be vetoed** from `webview_windows`; off-site navigations are
  undone by reloading the embed URL (as `onUrlChange` does on Android), and
  popups are denied outright.

### Buffer gaps

Some feeds leave holes in the buffer (seen: 1–4s and 9–18s buffered, nothing in
between). Playback stalls at the hole, and `hls.liveSyncPosition` can point back
into the stale stretch, so "jump to live" replayed the same few seconds forever.
The watchdog now hops to the next buffered range after ~1s of stalling, and
only trusts `liveSyncPosition` when it lies inside the buffer. This applies to
Android too.

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
crash), a failed link refresh keeps the old link, and `quitRequested()` reads
the `quit` field instead of draining the message port, which also carries the
stream server's socket events. Getting any of these wrong crashed the app on
2026-09-24 whenever a reconnect met a slow fetch. (With the debug console
attached, a crash freezes the app in the debugger rather than exiting it.)

Source reliability differs: on 2026-09-24, admin's 720p segments (TikTok's CDN)
had 2 of 1,794 downloads over 5 s; foxtrot/hotel's 1080p segments (the site's
own servers) had 12 of 891, each ~11 s against 6 s segments, enough to stall.

Things that were tried and didn't pan out: headers/HTTP-2 tricks for the
playlist (it's the TLS fingerprint), and a server relay that re-serves the video
(works, but unnecessary once the Roku can unwrap segments itself).

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
