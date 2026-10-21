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

Not always, though: on 2026-10-10 golf's ABC HD stream served its segments from
`lb18.strmd.st/m/…`, which refuses (403) anything without `Referer` or
`Origin: https://embed.st` (tested with curl: either header alone gets 200).
The phone and desktop fetch from inside the page, so they send it anyway; the
Roku's segment downloads now send both too (TikTok's CDN doesn't mind them).
Before that the TV stalled on every segment and took ~3 minutes of reconnects
to fall back. A stream whose first two segments are both refused is now given
up at once (no reconnects), so falling back takes ~10 s.

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
like any other source's; the notice only appears because it's framed. The apps
follow the embed page's first cross-site `<iframe>` (the middle page, fetched
with the embed page as Referer), decode the inner address from its
`atob("…")`, and play that page instead: `StreamedApi.innerPlayerUrl` on
phone/desktop (`_playInner` loads it in place), `playerPageUrl` in
`streamlink.brs` on the Roku (the server's Chrome opens it; the background
link-refresher reuses it). The stream keeps its golf embed URL everywhere else
(quality, recents, fallback).

**By what the page does, not by source (1.0.124).** Until then only sources
marked `nested` in `shared/app_data.json` (golf) were looked into, before the
page loaded. Now any page that has no playlist after 2 s and puts a player
(not its 1x1 `/ad.html`) in a frame from another site gets the same treatment:
the page script posts `nested` and the app plays the inner page
(phone/desktop); `findPlaylist` checks the frame and navigates to it (Roku).
So a source that starts nesting is covered, and the `nested` list is gone.
Golf starts ~2 s later than before (tested 2026-10-16: the phone played ~8 s
after "nested", the TV 8 s after loading the embed page). If no inner page is
found, the page still reports `blocked` after 10 s as before.

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
- **The lists disagree about a game's sources.** On 2026-10-10 Alabama-Georgia
  had admin and golf on `/api/matches/all` and the football list but admin only
  on `/api/matches/live`, while Oklahoma-Texas had admin only on the live one;
  both kept changing for the rest of the evening. Golf's stream was real (600+
  viewers). So wherever a game's streams load (the game page, the player's row
  and falling back), its sources are those of the list it came from plus the
  live and full lists' (`currentSources` / `mergeSources`). The player had used
  the full list alone and its row lost all four admin streams. On the TV the
  merge happens when the game list loads, since one screen handles every list.

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
| Quiet background refresh | on returning to the app, and on Back to any screen | every minute idle, on returning or window focus, and on Back to any screen | every minute idle, and back to Home or from a stream (until 1.0.111 these waited for data 30 s old on phone/desktop, a minute on the TV) |
| Refresh by hand | pull down | refresh button; no pull (a trackpad's scroll counts as a drag, so scrolling past the top refreshed) | none: the quiet refresh covers it |
| App bar while the list scrolls under it | tinted (Material's default) | stays flat: inside the inset frame a tinted bar is a floating box | n/a |
| Streams grouped by source, best first, described | yes | yes | yes |
| Measured quality on played streams' rows | yes, and "adaptive" when the source has more than one quality (it may play lower or higher another time) | same | yes; never adaptive: the TV plays the best feed only |
| A stream that recently failed | "Failed 12 min ago" where its quality goes, for an hour or until it plays; last in the row and when falling back | same | same; on the row's card the note and the language are on separate lines |
| Which of a source's qualities plays | the best to start (see the weak-connection row) | same | the best, never switched |
| A stuck segment download | second copy after 4 s if nothing is arriving | same | second copy after 4 s |
| Title bar with the game and quality in the player | from the start, and after switching streams, until the quality is known; then tap, or the menu; always in debug builds | the same, then mouse movement, or the menu; always in debug builds | the same, then OK (until 1.0.113 none of the apps held it again after a switch) |
| Title bar, Streams pill and note fade in and out | 150 ms (the note 250); the row fades too when it goes by itself with the title bar, and goes at once when closed by hand | same | same, since 1.0.116 (before, they appeared and vanished); the row's fade since 1.0.117 |
| Player menu button | shows and hides with the title bar | shows and hides with the title bar, fullscreen included; the pointer over the video hides with it, in a window too | no menu: the remote's buttons |
| Streams row in the player (this game's other streams, recent games) | Streams pill with the title bar; tap it; tap away or Back closes | Streams pill; click it; click away or Esc closes | Streams pill with the title bar; Down, then Left/Right, OK; Up or Back closes |
| Quality on a weak connection | steps down a source's separate feeds; back up only from a "1080p" button offered once the connection holds (hls.js switches both ways where they line up), saying so under a brief spinner; a "Weak connection" note when there's nowhere lower | same | the best feed always |
| A stall mid-stream | the last frame stays up while the player heals itself (hops gaps, rejoins live); a spinner only after 20 s with no progress, with "Reconnecting…" / "Waiting for connection…" | same | our spinner as soon as the player reports buffering (the Roku's player decides); stuck after the source skips ahead, or it skips 30 s or more, the player starts again at live (see "Stuck after the source skips ahead") |
| No pause (live streams only; a pause would just fall behind live) | no pause control | no pause control | Play/Pause shows the title bar like the other buttons |
| A stream that fails for good | tries the next like it (HD for HD, SD for SD), then the other kind, then "unavailable" | same | same |
| Reconnecting by itself after a stall or outage | yes | yes | yes |
| A source's server dropping the stream mid-game | reload after 20 s (a visible restart) | reload after 20 s (a visible restart) | fresh link in the background, usually unnoticed; see "Servers that drop a stream" |
| First link doesn't answer | "unavailable" | "unavailable" | two more fresh sessions first |
| Picture-in-picture, now-playing notification | yes (no picture-in-picture on a car's screen) | no | no |
| On a car's screen (Android Auto) | yes, the whole app, moving between the phone and the car as it plays (see Android Auto) | n/a | n/a |
| Fullscreen, keyboard shortcuts, remembered window | no | yes | no |
| Light and dark themes | yes; always dark on a car's screen | yes | dark only |
| Version in Settings | yes | yes | yes |
| Updates | through Obtainium | checks only on Home: at start, when the window gets focus, and on coming back to Home, at most hourly (`updates.checkEveryMinutes`); a version you said "Not now" to waits for the next start; installs itself and restarts | checks at start and hourly, says one is available; installing is up to the user |
| Asks before exiting on Back | no | no | yes: TV convention |
| Needs the Chrome stream server | no | no | yes (see Roku) |
| `golf` streams | play (inner page opened directly) | play | play; since 1.0.123 its segments come through the page (see "Segments only the page may fetch") |

## Android Auto (1.0.119)

The phone app runs on a car's screen, the whole app as it is, not a car
version: Android Auto starts `MainActivity` on a display of its own. The way
in is the one AA Browser uses (github.com/kododake/AABrowser), and it needs
Android Auto's developer settings with **Unknown sources** on; no AAAD.

- **Manifest:** the activity's launcher filter adds `CAR_LAUNCHER` and
  `androidx.car.app.category.NAVIGATION`; `distractionOptimized` on the app
  and the activity; `com.google.android.gms.car.application` pointing at
  `automotive_app_desc.xml` (`media`); `minCarApiLevel` 7; the
  `ACCESS_SURFACE` and `MAP_TEMPLATES` permissions; `resizeableActivity`.
- **`android:appCategory="game"` is what gets it in.** Without a category
  Android Auto's validator logs `Package DENIED; Not allowed native app -1`,
  and with `video` (what Google's parked video apps declare) `... app 2`.
  As a game it's listed. Android Auto then keeps it to parked use by itself,
  despite `distractionOptimized`: once the car is moving it takes the app
  off the screen (back to its home screen; the sound stops, as in the
  background) and won't open it, and once parked it opens again, back on the
  stream at live. Tested with the DHU's `restrict all` / `speed`.
- **One app on one screen.** It's a single activity, so it's on the phone
  or the car, never both. Opening it on the phone moves the activity there
  (a configuration change; it keeps running). Opening it on the car is a
  fresh activity, because Android Auto clears the task, so the app's state
  lives in a cached `FlutterEngine` (`provideFlutterEngine`,
  `shouldDestroyEngineWithHost` false) that the new activity picks up: a
  stream playing on the phone carries on in the car, and back again, with no
  buttons for it.
- **Ending the app.** A finishing activity ends the engine 3 s later unless
  another one has taken it, and only if it's the one using it (the one the
  car replaces is destroyed after its replacement starts; ending the engine
  then crashed the app on the next configuration change, in
  `FlutterJNI.updateDisplayMetrics`). Unplugging closes the activity on the
  car (its display is gone by `onDestroy`): then the engine waits 30 minutes,
  stopped as in the background, so opening the app on the phone returns to
  the stream at live.
- **The video after a move** stayed at the old screen's size, in a corner,
  so the player's web view is rebuilt (keyed on `onCarScreen`) when it moves;
  the page and the stream carry on.
- **The `car` channel** tells the app which screen it's on (`isOnCar`,
  `onCarChanged` from `onConfigurationChanged`, `attached` when a new
  activity takes the engine). On the car it's always dark and has no
  picture-in-picture.
- **Fullscreen on the car (1.0.120).** Android Auto gives an app like this
  (its own screen, not templates) only a small bar of its own, a back arrow
  and the app grid; the full bar Maps shows (media, time, notifications)
  isn't on offer. Where the car puts that bar at the bottom (the user's
  Chevy, and the DHU's `default_6in.ini`), it sat over the bottom of the
  video, and the list screens showed two back arrows, ours and Auto's. So on
  the car the app hides the system bars (`immersiveSticky`, re-applied on
  every move, since each is a new window; a swipe from the edge still shows
  Auto's bar), and every screen has our own back: the lists' as before, a ←
  in the player's title bar, and on Home an exit back to Android Auto. The
  phone is unchanged (edge to edge, system back).
- In the background, as on any phone, the stream stops (the web view
  pauses); returning jumps to live.
- **Android Auto connecting or shutting down paused the stream on the phone**
  (1.0.134). It takes the sound (audio focus) as it connects, and briefly
  again as it shuts down; WebView pauses on that and lets go of the sound for
  good, so it stayed paused (2026-10-19, both ends of two drives; seen in
  `dumpsys audio`'s focus history: gearhead's requests, then the app's
  `handleLoss`). The app has no pause of its own (none on screen, in
  picture-in-picture or in a notification), so a pause while the page is
  shown plays on a second later (`playOnAfterPause`, phone and desktop);
  "paused by the system: playing on" in the log.

### Testing it

The desktop head unit (DHU) on the PC, with the Pixel's real Android Auto
over wireless debugging. The emulator's Android Auto is a stub and its
Google APIs image has no Play Store to update it (the Pixel's Play Store needs
API 34).

- DHU **2.1** (`desktop-head-unit-windows-x64_r02.1.zip` from
  dl.google.com/android/repository; it's on the SDK's preview channel).
  2.0, the one `sdkmanager` offers, sat at "Waiting for phone…".
- On the phone: Android Auto settings, ⋮, Start head unit server (developer
  mode first). Then `adb forward tcp:5277 tcp:5277` and
  `desktop-head-unit.exe -c config/default_720p.ini`. The first time, accept
  the new car on the phone.
- The DHU's console takes `tap x y` and `screenshot <file>` (in the car's
  resolution), so it can be driven from a script with a file piped to stdin.
  Check a screenshot after every tap: blind taps landed in Maps and started
  navigation once. `default_6in.ini` (800×480) has the bar along the bottom,
  as in the user's car; `default_720p.ini` has it down the left. Connecting
  often fails every other try ("Waiting for phone…"); start it again.
- The released app and the dev build are both "sports" in the car's
  launcher; check which one opened with `dumpsys activity activities`.
- After reinstalling, opening it on the car can say "This can't be accessed
  on your Android Auto at this time"; OK, and open it again.
- Install the development flavor on the phone (`com.micahmo.sports.dev`):
  debug builds can't replace the released app.

## Windows

The player's web view is `webview_flutter` on every platform: Android's own,
and on Windows WebView2 through `webview_win_floating`, which implements the
same interface (since 1.0.115; before that `webview_windows`). The takeover
script and the `AppPlayer.postMessage` channel are shared.

### Native desktop player (1.0.115)

**Why.** `webview_windows` drew WebView2 off-screen and copied each frame into
a Flutter texture (Windows.Graphics.Capture), out of step with the video, so
60 fps never looked smooth: nothing was dropped (CPU under 30%, the Iris Xe
decoding at ~24%, the video element's counter clean apart from small bursts),
but frames were held unevenly. The same game in Firefox on dprec11 was "night
and day" (user, 2026-10-11), and so was a test build with `webview_win_floating`,
which puts a real WebView2 window over the app.

**The cost: Flutter can't draw over it,** so on Windows the page draws what sits
over a playing video (title bar, Streams pill and row, notes, menu): the app
keeps all the logic and sends what to
show after every build (`_overlay()` → `__appOverlay.render`), and the page
sends clicks back (`ui:pill`, `ui:stream:<i>`, ...). Sizes are the app's logical
pixels scaled as WindowScale scales (window width / 1360); colours from
app_data.json; the app's fonts (Barlow Semi Condensed 600/700, Material Icons)
are handed to the page as data URLs. Matching Flutter, measured against the old
app on dprec11:
- The menu's hamburger is drawn at 22 × 32/56 ≈ 12.6: flutter_speed_dial makes
  a 56 px button and shrinks it to 32, icon and all (13 × 8 px of lines in a
  45 px circle at 1.41x). Its icon stays a hamburger when open (no ✕), and the
  children scale in one after the other (Interval(i/n, 1), 150 ms).
- An icon alone in a round button sits 0.12 em lower than the browser puts it
  (it was 2 px above centre); beside text (the pill) it already matches.
- InkWell's ripple and the 150 ms fades are CSS; the hand cursor over buttons
  is Flutter's own desktop default too.
- In a shadow root, so the site's styles (in force until build() replaces its
  page) can't reach it: they centred the title for a moment.

**Waiting shows only the app's own screen, as on the TV.** Whenever the player
waits (a page loading, from the first stream to a switch, a fallback, Refresh
or a reconnect; a stall; a quality switch; "unavailable"), the web view sits
off-screen and the app's own spinner, text and Retry show, as on the phone and
the TV (where the app always draws its own spinner). It moves into place once
our script has the page and the stream plays (`_reveal()`). The page never
draws a spinner, so nothing hands over: an earlier version drew one in the page
too, and the handover from the app's showed as a flicker, a frozen spinner and
text jumping a pixel or two. Off-screen rather than hidden: a hidden WebView2
drops its picture and shows a moment of black when shown again; off-screen it
keeps drawing, so the picture is there when it moves in. The plugin only places its window when it's laid
out, so the move changes the constraints too (loose off-screen, tight in place),
in one widget shape so the view isn't rebuilt. Found on the way:
- The page-open animation snapshots the new page on Windows, so its spinner sat
  frozen until it ended: the player's route has `allowSnapshotting: false`.
- The site's ad scripts add a transparent full-window layer (`div#dontfoid`,
  z-index max) that ate the first click on the overlay. Once build() has the
  page, everything but our video, overlay and relink frame is hidden.
- WebView2's status bubble (a link's address, bottom left) is turned off.
- Leaving the player: the page fades to black (150 ms), the window moves
  off-screen, then the route pops, so the app's black player screen animates
  out as on a phone (the native window can't take part in the animation).
- Leaving also disposes the native window; otherwise it only hides, and the
  stream plays on, sound and all, until it's garbage-collected.
- The page keeps its last 300 log lines in `window.__appLog`, for reading over
  the debug port (desktop has no log to read).
- **A debug port on a PC that asks for one** (1.0.128): the runner (main.cpp)
  adds `--remote-debugging-port=<n>` when `%APPDATA%\com.micahmo\sports\debug-port`
  holds a port number. Nobody else has the file, and WebView2 listens on that
  PC alone (127.0.0.1), so it's reached over SSH (`ssh -L 9334:127.0.0.1:9333
  dprec11`). dprec11 has it (9333), so the player can be looked at live when
  something shows, without relaunching and losing what's in memory. It lasts
  through updates (the file isn't in the app's folder).

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
  click lands on Flutter. The Windows runner (main.cpp) adds
  `--autoplay-policy=no-user-gesture-required` to
  `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS` before the app starts, keeping anything
  already there (a debug port).
- **The viewer's mute stays** (1.0.129, phone too). Every new player started
  with sound (`play()` set `muted = false`): a switch to another feed (built
  afresh, see "Separate feeds") or a reload unmuted a muted game (2026-10-18,
  RedZone dropping to 540p). The choice is the viewer's alone (M or the menu,
  `_wantMuted`); the page keeps it in `__appWantMuted`, the app hands it to
  each page it loads, and `play()` follows it. The browser muting a refused
  autoplay doesn't count as a choice.
  Each new player also says its mute as it starts (1.0.131): one starting
  with sound sends no change, so after the browser had muted the last one the
  icon said muted over a game playing with sound.
- **Going fullscreen froze the picture.** Taking the window's frame off (and
  putting it back) has WebView2 report the page hidden for ~3 ms, and the
  browser pauses the video; nothing played it again, and the app's watch
  treats a paused video as fine. The page now plays on when it's shown again
  if the pause came while it was hidden (a pause while shown, as from
  Android's picture-in-picture controls, stays). Seen and fixed 2026-10-17
  (1.0.125); the log says "paused while the page was hidden: playing on".
- **The pointer stayed on the picture in fullscreen.** The page sets
  `cursor: none` as the title bar goes, but WebView2 changes the pointer
  without the mouse moving only while it has keyboard focus, and F (pressed
  in the app) leaves focus with Flutter: the arrow stayed, with the page's
  cursor already at none (seen on dprec11 over the debug port, 2026-10-17).
  Hiding the pointer now gives the web view focus first (requestFocus); the
  page hands Esc, M and F back as before.
- **The pointer hides in a window too** (1.0.128), over the video once the
  title bar goes, as YouTube does. The focus it needs (above) is taken only
  while the app is the window in front (`windowManager.isFocused`), never from
  another app the mouse happens to rest beside.
- **Keyboard focus.** Once the video is clicked, WebView2 holds keyboard focus
  and Flutter never sees keys, so the page forwards Esc/M/F as `key:<name>`
  messages.
- **Navigation:** off-site navigations and new windows (ads) are refused by
  the same NavigationDelegate as on Android.

### Playlists and segment downloads (phone and desktop)

**Separate feeds: never handed to hls.js as one.** A master playlist lists a
source's qualities, but on some sources they are **separate feeds**, not
renditions of one stream. Seen on admin streams (2026-09-30): "1080p" in 5 s
segments numbered from 83,350 on tiktokcdn with program-date-time tags, "540p"
in 3 s segments numbered from 2,367 on the site's own host, without them. Every
player assumes a source's qualities line up, so switching between these lands
on the wrong stretch: hls.js replayed the same few seconds over and over. That
was the phone's loop on a 1080p60 source, and 1.0.88 (which handed desktop the
master too) made desktop do it on every admin stream. From 1.0.89 the phone and
desktop played only the best feed, as the Roku always has (`pickMedia`): no
stepping down on a weak connection, and a 12.7 Mbps 1080p60 feed on one bar of
5G never started at all (2026-10-04).

**Adaptive again, safely (phone and desktop, 2026-10-07).** The takeover reads
the master and each feed's playlist once (`readFeeds()`):
- **Feeds that line up** (the same target duration, numbering within 2): hls.js
  gets the master and switches as it likes, as before 1.0.88.
- **Separate feeds:** we switch (`adapt()`, `switchFeed()`), by loading the
  other feed afresh at live, which can't land on the wrong stretch. Down after
  two segments in a row that came in under 110% of real time
  (`player.downPercent`), or at once when a download under way is slower than
  the feed needs while starting (after 6 s) or stalled for 3 s. Each switch is
  a brief spinner saying why ("Weak connection · Switching to 540p…"). A
  reconnect keeps the feed it had stepped down to (the app passes it in);
  opening the stream again, or another, starts from the best.
- **Never back up by itself (1.0.118).** It used to go up once segments had
  come in at 150% of what the better feed needs for a minute straight
  (doubling the wait after an up that didn't hold). But a switch loads the
  feed afresh: a gap in a stream that's playing fine, maybe at a moment that
  matters, and on a phone connection that swings it went 1080 → 540 → 1080
  over and over, a restart each time (2026-10-14, "a lot more buffering than
  normal"). Going down replaces something already failing; going up
  interrupts something that works. A seamless up (the better feed warmed in a
  second player, swapped in once playing) is parked.
- **Offered instead (1.0.118).** Under the same rule the old auto-up used
  (segments in at 150% of what the better feed needs for `upHoldMs` straight,
  doubled after an up that didn't hold) the page tells the app `canup:1080p`,
  and `canup:` when it no longer holds. The first time for a stream, "1080p
  available" comes up by itself where the notes go, for `upOfferMs` (8 s),
  and fades; after that a "⬆ 1080p" button sits left of the Streams pill
  (centred without one) whenever the title bar is up and the offer holds. A
  tap switches up (the brief "Switching to 1080p…" spinner). The pop-up goes
  at once when the title bar comes, so the two never overlap. Left of the
  pill because on a phone the right side runs into the menu button: the
  first build put "1080p available" there, which overflowed into it and drew
  garbled, and the emulator's GPU crashed on it every time (exit 139).
  Desktop draws the same in the page (`aoUp`, `aoUpNote`). Tested: down to
  540p at 4 Mbps; the offer about 70 s after the throttle lifted; a tap
  played 1080p in 2 s.
- **Nowhere lower to go** (one feed, or already the lowest) and stalled on a
  slow download: a "Weak connection" note, once a minute at most. Since
  1.0.118 also when stuck with nothing coming at all, a dead zone (a segment
  download with nothing after 3 s, or the playlist failing to load in the
  last 20 s), as the freeze starts: before, only a slow download counted, so
  in a dead zone the note came as the signal trickled back (2026-10-14).
  **The connection, not the source** (1.0.131, `networkSuspect()`): the note
  and a step down both need the connection to look bad, not just a segment.
  On Wi-Fi, RedZone's server took 4-10 s for 3 s segments while its playlist
  came back in ~100 ms; the app said "Weak connection" and dropped to 540p,
  which stalled anyway (2026-10-18). Suspect: playlist requests with no
  answer at all (an HTTP error is the server answering), most of the last few
  segments barely faster than the feed needs *once they were coming* (a long
  wait for the first byte is the server), the segment under way still
  arriving but slowly (one that went quiet and got a second copy is the
  server: the same line Hedged draws), or nothing back quickly for 5 s.
  Tested with CDP: every segment held 5 s before it was sent, 50 s, no step
  down and no note; a 2 Mbps throttle on 1080p, down to 540p 3.6 s into the
  stall. A server that sends steadily but slowly still looks like a slow line.
  **The offer goes while struggling** (1.0.131): "1080p" was only reconsidered
  as segments finished, and in a weak zone few do: it stayed up over a stuck
  540p, and taken, held 5 s (2026-10-18, phone). Now a slow or stalled
  download, or a stuck picture, withdraws it and restarts its minute. Tested:
  offered, then cut to 30 kbps, withdrawn 7 s later.
  Not while the page is hidden, nor for 5 s after it's shown again (1.0.130,
  `judging()`; the feed switching down waits the same): back from Home on
  Wi-Fi, "Weak connection" was already up (2026-10-18), Android having slowed
  or cut the backgrounded app's network. A download under way is timed from
  the page being shown, and link errors from before don't count.
  Never over the reconnecting spinner, nor in the 30 s after it lifts. Tested
  by holding the web view's requests for 30 s: the note 4 s into the freeze,
  none once it recovered. A stall while
  video is still arriving, however slowly, waits rather than reconnecting
  (starting again only threw away what was coming).
- **Slow to start:** after 20 s (`slowStartMs`) the spinner says why: "Still
  loading · your connection is slow" (a download coming in slowly, or the last
  one was slower than real time) or "… the stream is slow to respond" (nothing
  arriving; "Waiting for connection…" if the site can't be reached). It keeps
  loading; nothing gives up. The old 15 s "never started" restart no longer
  fires while a download is coming in.
- **Nothing at all at the start (1.0.121):** after 10 s with not a byte, the
  stream's lowest feed is tried (ours, or hls.js's lowest level where the feeds
  line up, back to its own choice once a segment is in), once, before the 15 s
  "never started" gives up on the stream and falls back to another. Before,
  1080p that couldn't get anything through on a weak connection went straight
  to another source's SD stream, marked the HD one "Failed", and left nothing
  better to offer later (2026-10-14, in the car). Now it stays on the stream,
  and the "1080p" button can take it back up. A true dead spot costs ~10 s
  more before the fallback. Tested with a proxy on the PC that holds the
  segment host's connections open (`settings put global http_proxy`):
  nothing for 10 s, then 540p, playing 2 s later. (A way back to the stream a
  fallback left was considered and dropped: it should only follow a fallback
  the app made, not one the user picked, which got complicated.)
- Tested on the emulator by throttling the web view's own downloads (DevTools
  `Network.emulateNetworkConditions`, re-applied every 2 s so a reload can't
  drop it; the emulator's `network speed` stalls downloads outright rather
  than slowing them): 4 Mbps went down to 540p in 7 s and back up a minute
  after the throttle lifted; 100 kbps gave the slow-start message; 200 kbps
  (540p needs ~250) gave the note and waited instead of reconnecting. The TV
  stays on the best feed: it has the bandwidth.
- Also fixed on the way: catching up to live only jumps to buffered video (on
  a slow connection it jumped past the end every 10 s, leaving nothing to
  play), and a slow first segment no longer reads as a 20 s stall the moment it
  starts to play (the timer starts when it plays). Progress for the 20 s timer
  is half a second of video over the last 2 s: hls.js's 0.1 s nudges stay
  under it, a slow decoder still counts. The hops and restarts count any
  movement, as before (counting stutter as stuck, 1.0.104, had them firing
  every few seconds on a weak connection).
- When checking playback, check that `currentTime` keeps advancing, not just
  the quality label. The takeover logs what it tells the app (`tell app: …`).

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

**Fresh links without stopping (phone and desktop, 2026-10-11).** The
playlist link is tied to the network it was fetched on: on 2026-10-11 every
switch between Wi-Fi and cellular broke it (the phone's log: "levelLoadError"
every 3 s), and the player sat through ~25 s of that, stalled and reconnected,
a reload with its own spinner. Now two playlist failures in a row, once the
stream has played, start `linkFailing()`: the page loads again in a hidden,
muted frame, the first playlist it asks for is a fresh link (for the network
the phone is on now), and a wrapper on hls.js's playlist loader
(`relinkedLoader`, and the segment loader too) sends every request for the old
link there. hls.js never sees a new link, so it keeps its buffer and timeline.
Handing it the new link with `loadSource` instead restarted both: a jump back
and a 12 s freeze. Tested on the emulator by blocking the playing link through
the DevTools protocol: single-feed stream, fresh link in 3.1 s and playback
never paused (the position advanced 3 s every 3 s throughout). On admin's two
separate feeds the requests moved to the fresh server (200s), but the emulator
couldn't hold the 8 Mbps feed long enough for a clean run. The source's
numbering matched across links in both feeds (1080p 272,321 → 272,322; 540p
2,209 → 2,210 a moment apart). At most once every 20 s; if it fails, the stall
watch still reconnects as before. (The user's rule since: prefer the seamless
fix over a quick visible one.) The Roku already did the equivalent (a new link
found in the background while it serves the last playlist).

Two more ways in, the same swap (2026-10-11):
- **A playlist that stops moving.** No new segment for three segments' time
  (10 s at least) while the playlist still loads: the source's server may
  have stalled while others carry on, and a fresh link often lands on another
  server. Tested by freezing the playing link's playlist through the DevTools
  protocol: noticed at 10 s, a fresh link on another server in 2.9 s, and
  playback never paused.
- **Back online.** When the app's own check sees the network come back
  after a dead zone, it asks the page to swap (`__appPlayer.relink()`) and
  waits 8 s for "playing" before reloading as before. The page's own "online"
  event is wired up too, but didn't fire on the emulator. A swap that finds no
  link (offline) gives up after 10 s, and doesn't count toward the 20 s limit,
  so the next failure after the network returns tries again at once.
  On the emulator the swap fired and found a fresh link in 1.8 s, but that
  stream was stalling on its own, so the app still reloaded after the 8 s; the
  real test is a phone in a dead zone.

**No busy loop offline.** hls.js was told to load again the moment a fatal
network error came in; with no network at all every request failed at once, so
it went round ~80 times a second (1,560 errors in 20 s on the emulator). Now a
second later, and only one pending (13 errors over the same test).

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

**A cushion in seconds** (phone and desktop, 1.0.136). hls.js started 3
segments behind live, so a source with 3 s segments (admin's RedZone) left
~9 s in hand, and a playlist standing still 11-13 s froze the picture (four
times on 2026-10-18). Starting further back wasn't possible: admin lists only
its last 4 segments (12 s), and a player behind them jumped to live, losing
what it had banked. Now the playlist loader (`longerList`, in
`relinkedLoader`) keeps listing the last 45 s of segments after the source
drops them, as the TV's proxy does (the CDN still serves them; checked a
minute on), and hls.js aims 18 s behind live, or 3 segments if those are
longer (only short-segment sources change, ~9 s further behind live). The list
is per playlist and carries through fresh links (`relinked` maps the old
ones); it starts afresh after a gap in the numbering (segments missed) or a
restart, takes each segment's tags as the source lists them now (the clock tag
goes on whichever segment is first), backs listed discontinuities out of the
discontinuity sequence, and leaves alone playlists with keys, maps, byte ranges
or an end. Tested on the emulator (Willow SD, 3 s segments): 12-15 s buffered
ahead instead of ~9.

**A refused segment is skipped** (1.0.136). On 2026-10-21 admin's segment CDN
refused some segments (403) to any request carrying embed.st as Origin or
Referer, and served them to plain requests (so not the TV, whose proxy sends
neither; a page can't leave its Origin off). hls.js asked for the refused one
again every second until the app reloaded the stream 20 s later, then hit it
again; today's release did the same. Now a segment refused (403, 404) twice is
skipped once the player gets to it: it's next, and under a second is left or
the video has stopped for want of more (it stopped 1.4 s short of the end of
what it had on the emulator, and where hls.js thinks a segment starts can be
as far off). Tested with one segment refused on purpose (CDP Fetch): skipped
3 s after the stall, no reload, played on.

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
  playing first, best sources first; recently failed ones last, so they only
  show when there's room (user, 2026-10-08: "keep showing it unless there are
  better options"), with the failure in the quality's place.
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
  user, 2026-09-30), and only then "unavailable". Recently failed streams come
  after every other: working ones of either kind first.
- **Recently failed:** a stream that fails for good is remembered like its
  quality (`StreamFailures` / `failedNote()` in common.brs), through restarts,
  for `player.failedForMinutes` (an hour) or until it plays. Its quality line
  says "Failed 12 min ago" in a soft red (`palette.failed`, not the LIVE red),
  in the streams list and on the row's card. Relative, not "at 8:26 PM": the
  clock time didn't mean much (user, 2026-10-08). Until 1.0.109 a failure was
  forgotten when the player closed, so it came back as an untried stream.
  On the Roku the row card puts the note and the language on separate lines
  (a label has one colour).
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

For the 20 s timer, progress means half a second of video or more over the
last 2 s (first, in 1.0.104, 0.2 s per half-second check, which also drove the
hops and restarts and fired them on mere stutter; see "Adaptive again"). hls.js
nudges the playhead 0.1 s at a time when stuck, and those used to count, so in a dead zone the watchdog never read the stream as stalled: the
picture sat frozen with no word for as long as the network was gone. Now after
20 s it tells the app, which shows "Waiting for connection…". And when the
stream plays on by itself after that (the network came back), the page tells
the app "playing" again: it used to say so only once, so the spinner stayed up
over the playing stream, sound and all, until the app's next look (up to 10 s).
Tested on the emulator with the network off for 70 s: the message came up, and
the spinner lifted ~4 s after the network returned, the same stream playing on.
The player page is also exactly the screen's height now (the video sat on a
line of text, 4 px taller, and the page could be scrolled by that).

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

**Every stream starts with the hold** (1.0.135). At the edge with nothing
banked, every TV spinner reported 2026-10-08 to -19 (ten of them) came from
the source standing still 13-20 s or one slow segment, and the stream was
steady once a reconnect's hold had put it behind. So a new stream (picked,
switched to, or fallen back to) holds 12 s the same way before it plays:
starting takes ~12 s longer. Tested: held 12 s, then played ~30 s behind the
newest segment instead of ~18. A restart at live (below) still starts at the
edge: by then the stall has spent the cushion anyway. Phone and desktop keep
a longer list of their own (see "A cushion in seconds" under Playlists and
segment downloads).

None of that helped while the proxy fetched the playlist and waited: a 17 s
playlist request held up the whole proxy, so the player couldn't get even the
segments it had in hand, and spun after ~15 s however far behind live it was.
The playlist is now fetched in the background like the segments (`askPlaylist`
in StreamTask): the player gets the source's newest if it comes within 1.5 s
(it takes ~100 ms), else the last good one, and segments keep flowing. Tested
with a build that held one playlist fetch in ten for 9 s: segments were served
all through each hold, no buffering. Phone and desktop already fetch playlists
in the background (hls.js).

### Segments only the page may fetch (1.0.123)

Some sources tie each segment link to whoever fetched the playlist. Golf began
doing it around 2026-10-15: the page in the server's Chrome fetches the
playlist, so its segment links worked for that page and were refused (403) to
the TV, which marked every golf stream failed and fell back. Checked from a PC
on the same public IP: refused whatever the headers, even connecting as Chrome
does (curl_cffi), even fetched before the page; but a playlist fetched there,
connecting as Chrome, gave segment links that played. Not the address, not
single-use links: the playlist's fetcher.

So when a segment fetched directly is refused, the TV fetches that one and the
rest of the stream's through the page (`viaPage`, `addTransfer` and
`pageSegment` in StreamTask, `segmentScript` in streamlink): the page fetches
the segment and hands it over as base64 through WebDriver, and the TV writes
it to a file and serves it as any other. It's triggered by the refusal, not by
the source's name, so any source that starts doing this is covered and the
others never pay for it. Measured: a 2.5 MB, 5 s segment arrives in ~0.5–1 s
to a PC and ~1.1–1.6 s on the TV (720p60 golf, 2026-10-16: playing 10.5 s
after starting, a few seconds slower as the first segments queue). No second
copy of a slow segment this way: the page's Chrome runs one script at a time,
so it would only queue behind the first. The video goes through the server
(fine on the LAN); phone and desktop don't need any of this, their web view
fetches both.

**Not for good** (1.0.127). A dying link refuses its segments too: on an admin
stream (2026-10-18) the link went (playlist 500), its next segment was refused
(403), and the TV went through the page for the rest of the stream, where
none of admin's segments came (its CDN, from the page: errors, or a page that
wasn't a segment), even after a working link arrived 4 s later. Every segment
failed for 25 s until the stall reconnected. So a new link starts direct
again, and a segment that doesn't come through the page either is fetched
directly at once, with the TV back to direct for the rest (that segment isn't
sent to the page again, so the two can't ping-pong). Golf pays one refused
request per new link.

### Stuck after the source skips ahead (1.0.122)

After the source stalls it sometimes comes back having skipped part of the
game, its segment numbering unbroken but the picture's own clock (the
segments' timestamps) 6 to 32 s further on, sometimes with a few segments
missed too. A player still playing goes straight over the jump. One that ran
dry in the stall doesn't: it takes segment after segment (18–21 s of video)
without playing until the 20 s stall reconnects, then the 12 s hold back:
~45 s of spinner for a ~15 s outage, several times on 2026-10-15.

- **Restart, not reconnect** (`onStuck` in PlayerScreen): buffering, and given
  15 s of video since the spinner came (`servedSecs` from StreamTask; a
  healthy start plays after ~12), the player is stopped and started again on
  the same proxy, which lists only its newest 3 segments for it (`trim`) so
  it starts at live. No new browser session, no hold back; once per spell of
  buffering, and the 20 s stall still reconnects if it didn't help. Seen
  working 2026-10-16: stuck 16 s after a 32 s jump, playing 1.2 s after the
  restart, ~20 s sooner than the old way.
- **A big jump restarts at once** (`onJumped`, 1.0.126): a still-playing
  player doesn't go over every jump. After an ~85 s outage the working link's
  picture was 80 s ahead (2026-10-17); the player raced through what it had
  ("going really fast"), stuck, buffered, then asked again for segments it
  had already played, a replay. So a jump of 30 s or more (`checkClock` sets
  StreamTask's `jumped` as the segment downloads, before the player asks for
  it) starts the player again at live the same way (20 s since 1.0.135: a
  25 s jump played over, 2026-10-19, and the player then asked again for
  segments it had played, a replay); once per jump, as the
  next segment, finishing out of order, reports it too (and a segment
  downloaded again isn't checked twice). Smaller jumps it plays over, and one
  it runs dry at is still onStuck's. Tested with a staged 18 s skip (threshold
  lowered for the test): jump seen, playing again 1.3 s later.
- **A restart drops what was going to the old player.** Stopped mid-segment,
  that player stops reading, and `sendAll` waited out its 10 s for it while
  the whole proxy served nothing: the new player sat on its spinner, then
  onStuck restarted it again (14 s, in the test). Each connection now carries
  the start of the player it came from (`startedAgain`, counted by
  `restartAtLive`), and a send to an older one is dropped as soon as it
  stalls.
- **No answer holds up the proxy** (1.0.132). Even so, a restart after a dry
  spell sat ~12 s: the *new* player asked for a segment and didn't read it at
  first, and the one-at-a-time send waited out its 10 s, then again, while
  nothing else was answered (not even the proxy's own playlist fetch), until
  the stall reconnected. Now each answer goes out as fast as its connection
  takes it (`respond` sends until the socket is full, `pumpAll` sends the rest
  every turn of the loop, polling every 5 ms while any is pending), and is
  dropped if it's for an older start of the player or takes nothing for 15 s.
  Tested (a staged dry spell: the list held still until the player had been
  dry 8 s, then the held segments released): playing 1.3 s after the
  restart instead of the ~12 s wait and a reconnect.
- **Stuck needs 2 s too** (1.0.132): after a dry spell the source can come
  back with several segments at once, so the 15 s of video arrived in a
  moment; `onStuck` now also waits for it to stay unplayed 2 s (a player that
  goes on by itself does within ~1 s; one that doesn't, didn't in the tests,
  so the restart is right). Staged: source back to playing in 4.2 s.
- **No replay after a jump's restart** (1.0.133). `restartAtLive` lists the
  newest 3 segments, and Roku's player starts at the top of the list, so it
  showed again the two it had just played (~10 s), every time (the log's
  sequence numbers: playing 748-749, asking 750 with the jump; restarted on
  748-750, it asked 748, 749, 750; 2026-10-19). Listing only what it hadn't
  had doesn't do: with fewer than 3 the player started over, spinner and all,
  as soon as the list grew. So the 3 stay, StreamTask says how much of them
  from the top the player has had (`skipSecs`), and once it plays PlayerScreen
  seeks on past that (and half a second, or it fetched the last one again).
  Tested with a staged 15 s jump: playing ~2 s after the restart, past the
  seek ~1 s later, then on; no replay. Only after a jump (the player was
  playing): a stuck player showed none of what it took, so that's game not
  yet seen, and a stuck restart plays it.
- **No replay after running dry** (1.0.135). Starting again after it ran dry
  at the end of the list, the player sometimes goes back and shows again what
  it played (~10-20 s; 2026-10-17, -18 and -19): rewinding inside what it has,
  with no segment asked for (2026-10-19 20:51), or asking again for segments
  it played (seven times in 25 s, 2026-10-19 23:03). Tried first: once it's
  dry, dropping the segments it had from the list: dry again 5 s later (too
  little listed), so not kept. Now PlayerScreen notes the position when it
  runs dry mid-game (`spellPos`), and if it plays again more than 3 s before
  that, seeks on to it (`checkReplay`, as it plays and a second on, since the
  position can lag; once per spell; not after `restartAtLive`, which starts at
  the top of its list on purpose). Instead of a replay: a spinner while the
  video comes. The staged dry spell never produced the rewind (the player got
  stuck instead), so tested with a staged 10 s rewind while playing: back to
  where it was in 0.4 s, then on. `askSegment` logs "the player asked again
  for a segment it had".
- **Tried and dropped:** marking the jump in the player's list
  (`#EXT-X-DISCONTINUITY`): the Roku's player went back to the top of the
  list, replayed it, then played garbled, fast and silent, and froze. Listing
  a segment only once its clock had been checked (to mark it in time).
  Counting downloaded segments not yet asked for as "stuck": some the player
  never asks for, and it restarted 3 s into a plain source stall.
- **Logged:** `checkClock` reads each segment's first timestamp as its
  download finishes and logs "picture clock jumps ahead N s" (comparing with
  the segment just before it in time, as downloads finish out of order), and
  every line of the debug console starts with the time of day (`logTime()`),
  which is what showed which step of a slow start or a long spinner took the
  time.

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
