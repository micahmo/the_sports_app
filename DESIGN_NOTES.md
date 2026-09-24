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

## The playlist URL only works inside the WebView

The signed `lb*.strmd.st/secure/<token>/…/playlist.m3u8` returns **403** when
fetched from anywhere else, even with identical headers and a fresh token. It is
not cookie-based (there are no `strmd.st` cookies) and not single-use. So a
native Flutter player (`video_player` et al) cannot be handed the URL — playback
has to stay inside the WebView that obtained it.

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
