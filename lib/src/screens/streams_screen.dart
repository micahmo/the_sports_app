import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_speed_dial/flutter_speed_dial.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import '../api/models.dart';
import '../api/streamed_api.dart';

const MethodChannel _nowPlaying = MethodChannel('nowplaying');

class StreamsScreen extends StatefulWidget {
  const StreamsScreen({super.key, required this.matchItem});
  final ApiMatch matchItem;

  @override
  State<StreamsScreen> createState() => _StreamsScreenState();
}

class _StreamsScreenState extends State<StreamsScreen> {
  final StreamedApi _api = StreamedApi();
  late Future<List<_Entry>> _future;

  // Remember last-picked stream (per list view instance)
  String? _lastPlayedUrl;

  @override
  void initState() {
    super.initState();
    _future = _loadAllStreams();

    // Ask, then show once granted
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _ensureNotifPermission();
      if (!mounted) return;
      await _showNowPlaying();
    });
  }

  Future<List<_Entry>> _loadAllStreams() async {
    final List<MatchSourceRef> sources = widget.matchItem.sources;
    // Fetch all sources in parallel
    final List<List<StreamInfo>> results = await Future.wait(sources.map((s) => _api.fetchStreams(s.source, s.id)), eagerError: true);

    final List<_Entry> entries = <_Entry>[];
    for (int i = 0; i < sources.length; i++) {
      final MatchSourceRef ref = sources[i];
      final List<StreamInfo> list = results[i];
      if (list.isEmpty) continue;

      entries.add(_HeaderEntry(ref.source));
      for (final StreamInfo s in list) {
        entries.add(_StreamEntry(s));
      }
    }

    return entries;
  }

  @override
  Widget build(BuildContext context) {
    final String title = widget.matchItem.title;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: FutureBuilder<List<_Entry>>(
        future: _future,
        builder: (BuildContext ctx, AsyncSnapshot<List<_Entry>> snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          }

          final List<_Entry> entries = snap.data ?? <_Entry>[];
          if (entries.isEmpty) {
            return const Center(child: Text('No streams available.'));
          }

          return ListView.builder(
            itemCount: entries.length,
            itemBuilder: (_, int i) {
              final _Entry e = entries[i];
              if (e is _HeaderEntry) {
                return _SourceHeader(source: toBeginningOfSentenceCase(e.source), sourceSubtitle: sourceSubtitles[e.source]);
              } else if (e is _StreamEntry) {
                final StreamInfo s = e.stream;
                final String subtitle = s.language.isEmpty ? '' : s.language;

                // Is this the last one we picked?
                final bool isLast = (s.embedUrl == _lastPlayedUrl);

                return ListTile(
                  leading: Icon(s.hd ? Icons.hd : Icons.sd),
                  title: Text('Stream #${s.streamNo}'),
                  subtitle: subtitle.isEmpty ? null : Text(subtitle),
                  trailing: Icon(isLast ? Icons.play_circle_fill : Icons.play_arrow),
                  onTap: () async {
                    // Set before navigating so it shows even if user backs out
                    setState(() => _lastPlayedUrl = s.embedUrl);

                    // Push the player
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => StreamPlayerScreen(stream: s, title: title),
                      ),
                    );
                  },
                  selected: isLast, // also gives a subtle highlight in many themes
                );
              }
              return const SizedBox.shrink();
            },
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _hideNowPlaying();
    super.dispose();
  }

  Future<void> _showNowPlaying() async {
    try {
      await _nowPlaying.invokeMethod('show', <String, dynamic>{'title': widget.matchItem.title});
    } catch (_) {}
  }

  Future<void> _hideNowPlaying() async {
    try {
      await _nowPlaying.invokeMethod('hide');
    } catch (_) {}
  }

  Future<void> _ensureNotifPermission() async {
    if (Platform.isAndroid) {
      // Android 13+ only (notification runtime permission)
      final status = await Permission.notification.status;
      if (!status.isGranted) {
        await Permission.notification.request();
      }
    }
  }
}

class _SourceHeader extends StatelessWidget {
  const _SourceHeader({required this.source, required this.sourceSubtitle});
  final String source;
  final String? sourceSubtitle;

  @override
  Widget build(BuildContext context) {
    final TextTheme t = Theme.of(context).textTheme;
    final EdgeInsets padding = MediaQuery.of(context).padding;

    return Container(
      color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5),
      padding: EdgeInsets.fromLTRB(16 + padding.left, 6, 16 + padding.right, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(source, style: t.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          if (sourceSubtitle != null) ...[const SizedBox(height: 4), Text(sourceSubtitle!, style: t.bodySmall)],
        ],
      ),
    );
  }
}

abstract class _Entry {}

class _HeaderEntry extends _Entry {
  _HeaderEntry(this.source);
  final String source;
}

class _StreamEntry extends _Entry {
  _StreamEntry(this.stream);
  final StreamInfo stream;
}

// embed.st hands the WebView a valid HLS url, then its own player bootstrap
// bails out and paints "Remove sandbox attributes on the iframe tag" over the
// page. That url is bound to the page session, so it cannot be fetched from
// Dart -- but it plays fine inside this WebView. So we let the page fetch the
// url, then throw its player away and run our own <video> + hls.js on it.
const String _takeoverJs = r'''
(function () {
  if (window.__appPlayer) return;
  window.__appPlayer = { url: null, built: false, revealed: false };

  var HLS_SRC = "https://cdn.jsdelivr.net/npm/hls.js@1.5.17/dist/hls.min.js";
  var hls = null;
  var video = null;
  var lastTime = -1;
  var stalledFor = 0;

  function post(msg) {
    try { AppPlayer.postMessage(msg); } catch (e) {}
  }

  // The Flutter-side cover is composited over a platform view, which lets the
  // page through for about a frame. Blanking it from inside the page as well
  // means the notice is never painted at all.
  function hidePage() {
    try {
      if (document.getElementById("appHide")) return;
      var st = document.createElement("style");
      st.id = "appHide";
      st.textContent = "html{visibility:hidden!important;background:#000!important}";
      (document.head || document.documentElement).appendChild(st);
    } catch (e) {}
  }

  function showPage() {
    try {
      var st = document.getElementById("appHide");
      if (st && st.parentNode) st.parentNode.removeChild(st);
    } catch (e) {}
  }

  hidePage();
  // The page can replace its own <head>; keep the blanking in place until we
  // decide what to do.
  setInterval(function () { if (!window.__appPlayer.built && !window.__appPlayer.revealed) hidePage(); }, 100);

  // The page requests the playlist itself; we read it back off the resource
  // timeline, which works however late we are injected.
  function findUrl() {
    try {
      var e = performance.getEntriesByType("resource");
      for (var i = e.length - 1; i >= 0; i--) {
        if (e[i].name.indexOf(".m3u8") !== -1) return e[i].name;
      }
    } catch (err) {}
    return null;
  }

  function loadHls() {
    return new Promise(function (res, rej) {
      if (typeof Hls !== "undefined") return res();
      var el = document.createElement("script");
      el.src = HLS_SRC;
      el.onload = function () { res(); };
      el.onerror = function () { rej(new Error("hls.js failed to load")); };
      (document.head || document.documentElement).appendChild(el);
    });
  }

  // These are live feeds, so being anywhere but the live edge is a bug.
  function toLiveEdge() {
    if (!video) return;
    try {
      if (hls && hls.liveSyncPosition > 0) { video.currentTime = hls.liveSyncPosition; return; }
      if (video.seekable.length) {
        video.currentTime = Math.max(0, video.seekable.end(video.seekable.length - 1) - 1);
      } else if (video.buffered.length) {
        video.currentTime = Math.max(0, video.buffered.end(video.buffered.length - 1) - 0.5);
      }
    } catch (e) {}
  }

  function play() {
    video.muted = false;
    video.play().catch(function () {
      // Autoplay with sound refused: fall back to muted so something shows.
      video.muted = true;
      video.play().catch(function () {});
    });
  }

  function build(url) {
    document.documentElement.innerHTML =
      "<head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"></head><body></body>";
    document.body.style.cssText = "margin:0;padding:0;background:#000;overflow:hidden";

    video = document.createElement("video");
    video.id = "appPlayer";
    video.autoplay = true;
    video.playsInline = true;
    video.setAttribute("playsinline", "");
    video.style.cssText = "width:100vw;height:100vh;object-fit:contain;background:#000";
    document.body.appendChild(video);
    video.addEventListener("volumechange", function () {
      post(video.muted ? "muted" : "unmuted");
    });

    if (hls) { try { hls.destroy(); } catch (e) {} }
    // Not low-latency HLS, and these feeds carry ad discontinuities, so keep a
    // real buffer rather than hugging the edge.
    hls = new Hls({ liveSyncDurationCount: 3, backBufferLength: 30 });
    hls.loadSource(url);
    hls.attachMedia(video);
    hls.on(Hls.Events.MANIFEST_PARSED, function () { toLiveEdge(); play(); });
    hls.on(Hls.Events.ERROR, function (_, d) {
      if (!d.fatal) return;
      if (d.type === Hls.ErrorTypes.NETWORK_ERROR) { try { hls.startLoad(); } catch (e) {} }
      else if (d.type === Hls.ErrorTypes.MEDIA_ERROR) { try { hls.recoverMediaError(); } catch (e) {} }
      else { post("fatal"); }
    });
    lastTime = -1;
    stalledFor = 0;
    play();
    window.__appPlayer.built = true;
    post("playing");
  }

  function takeOver(url) {
    window.__appPlayer.url = url;
    loadHls().then(function () {
      if (typeof Hls === "undefined" || !Hls.isSupported()) return post("unsupported");
      build(url);
    }, function () { post("hls-load-failed"); });
  }

  function watch() {
    // The page script may still wipe the body; put our player back if so.
    if (!document.getElementById("appPlayer")) { build(window.__appPlayer.url); return; }
    if (video.paused) return;
    if (video.currentTime === lastTime) {
      stalledFor += 1;
      // ~4s without progress: skip whatever we are stuck on and rejoin live.
      if (stalledFor >= 8) { stalledFor = 0; toLiveEdge(); video.play().catch(function () {}); }
    } else {
      stalledFor = 0;
      lastTime = video.currentTime;
    }
  }

  // Some sources (e.g. golf) put the real player in a nested cross-origin
  // iframe, which we can neither read nor take over. The page's own 1x1
  // /ad.html iframe does not count.
  function hasForeignPlayer() {
    var f = document.querySelectorAll("iframe[src]");
    for (var i = 0; i < f.length; i++) {
      if (f[i].src.indexOf("/ad.html") !== -1) continue;
      if (f[i].clientWidth > 100 && f[i].clientHeight > 100) return true;
    }
    return false;
  }

  // The page replaces itself with this notice when its own player gives up.
  // It can appear before we find the playlist, so it only counts once we have
  // waited a while without one.
  function pageGaveUp() {
    // textContent, not innerText: we blank the page with visibility:hidden,
    // and innerText is layout-aware so it comes back empty.
    var t = (document.body && document.body.textContent) || "";
    return t.indexOf("Remove sandbox") !== -1;
  }

  var tries = 0;
  var settled = false;
  var deadFor = 0;
  setInterval(function () {
    if (window.__appPlayer.built) {
      watch();
      // Took over, but the feed never actually started: say so rather than
      // leave a black screen up.
      if (video && video.readyState === 0 && !settled) {
        if (++deadFor > 30) { settled = true; post("fatal"); }
      } else {
        deadFor = 0;
      }
      return;
    }
    var u = findUrl();
    if (u) { takeOver(u); return; }
    if (settled) return;
    // Give the page ~10s to produce a playlist before judging it.
    if (++tries < 20) return;
    // Nothing watchable: the Flutter side puts its own message up, so leave
    // the page blanked rather than flashing the notice.
    if (pageGaveUp()) { settled = true; post("blocked"); return; }
    // A big cross-origin iframe means the real player is nested somewhere we
    // cannot reach (e.g. the golf source, which goes embed.st -> rockystream.st
    // -> embed.st again). Those inner pages are gated too and render the same
    // red notice, which we cannot read or hide from out here -- so stay blanked
    // and show our own message instead. If a nested source ever does work, this
    // is the branch to relax.
    if (hasForeignPlayer()) { settled = true; post("blocked"); return; }
    if (tries > 40) { settled = true; post("no-stream"); }
  }, 500);
})();
''';
// Native channel for Android PiP
const MethodChannel _pip = MethodChannel('pip');

class StreamPlayerScreen extends StatefulWidget {
  const StreamPlayerScreen({super.key, required this.stream, required this.title});
  final StreamInfo stream;
  final String title;

  @override
  State<StreamPlayerScreen> createState() => _StreamPlayerScreenState();
}

class _StreamPlayerScreenState extends State<StreamPlayerScreen> with WidgetsBindingObserver {
  late final Uri _allowedUri;
  late final WebViewController _controller;

  bool _inPip = false;
  bool _muted = false;
  // The embed page shows its own broken-player message before we take over,
  // so keep it covered until our player reports back.
  bool _ready = false;
  // Takeover failed and the page has nothing watchable of its own, so it is
  // just showing its red notice. Cover that with something presentable.
  bool _failed = false;

  // Rotation/PiP resume heuristics
  DateTime? _lastPipExitAt;
  bool _wentBackground = false;

  AppLifecycleState _appState = AppLifecycleState.resumed;
  bool _suppressOrientationMarking = false;

  Orientation? _lastOrientation;
  DateTime? _lastOrientationChangeAt;

  @override
  void initState() {
    super.initState();

    // Do NOT auto-enter PiP when user leaves (Home/Recents, etc.)
    _pip.invokeMethod('setAutoPipOnUserLeave', <String, dynamic>{'enabled': false}).catchError((_) {});

    // PiP state updates
    _pip.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'pipChanged') {
        final Object? args = call.arguments;
        final bool inPip = (args is Map && args['inPip'] is bool) ? args['inPip'] as bool : false;
        if (mounted) setState(() => _inPip = inPip);

        if (inPip) {
          // Do not record orientation changes while in PiP
          _suppressOrientationMarking = true;
        } else {
          _lastPipExitAt = DateTime.now();
          // Re-enable marking on next frame after we’re out of PiP.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _suppressOrientationMarking = false;
          });
        }
      }
      return null;
    });

    // Initial PiP state
    _pip
        .invokeMethod('isInPip')
        .then((dynamic v) {
          if (mounted) setState(() => _inPip = (v == true));
        })
        .catchError((_) {});

    _allowedUri = Uri.parse(widget.stream.embedUrl);

    // Build controller + allow autoplay on Android
    const PlatformWebViewControllerCreationParams params = PlatformWebViewControllerCreationParams();
    final WebViewController controller = WebViewController.fromPlatformCreationParams(params)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..addJavaScriptChannel(
        'AppPlayer',
        onMessageReceived: (JavaScriptMessage m) {
          if (!mounted) return;
          setState(() {
            // Anything other than success means we cannot do better than
            // showing the page itself, so stop covering it either way.
            if (m.message == 'playing' || m.message == 'passthrough') {
              _ready = true;
              _failed = false;
            } else if (m.message == 'muted') {
              _muted = true;
            } else if (m.message == 'unmuted') {
              _muted = false;
            } else {
              // no-stream / fatal / unsupported / hls-load-failed
              _failed = true;
            }
          });
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) {
            _cover();
            _inject();
          },
          onPageFinished: (String url) => _inject(),
          onNavigationRequest: (NavigationRequest req) {
            final Uri dest = Uri.parse(req.url);
            return _isAllowedDestination(dest) ? NavigationDecision.navigate : NavigationDecision.prevent;
          },
          onUrlChange: (UrlChange change) {
            final String? u = change.url;
            if (u == null) return;
            final Uri dest = Uri.parse(u);
            if (!_isAllowedDestination(dest)) {
              _controller.loadRequest(_allowedUri);
            }
          },
        ),
      );

    if (controller.platform is AndroidWebViewController) {
      final AndroidWebViewController a = controller.platform as AndroidWebViewController;
      a.setMediaPlaybackRequiresUserGesture(false);
    }

    _controller = controller..loadRequest(_allowedUri);

    // Always light status bar (icons) over black
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark, // iOS
        systemNavigationBarColor: Colors.black,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );

    // Go edge-to-edge but keep bars visible
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

    WidgetsBinding.instance.addObserver(this);
  }

  void _inject() {
    _controller.runJavaScript(_takeoverJs).catchError((_) {});
  }

  void _cover() {
    if (!mounted) return;
    if (!_ready && !_failed) return;
    setState(() {
      _ready = false;
      _failed = false;
    });
  }

  Future<void> _toggleMute() async {
    const String js = '(function(){var v=document.getElementById("appPlayer");if(!v)return "none";v.muted=!v.muted;if(!v.muted)v.play().catch(function(){});return v.muted?"muted":"unmuted";})();';
    try {
      final Object res = await _controller.runJavaScriptReturningResult(js);
      final String r = res.toString().replaceAll('"', '');
      if (mounted && r != 'none') setState(() => _muted = r == 'muted');
    } catch (_) {}
  }

  Future<void> _enterPip() async {
    try {
      final dynamic ok = await _pip.invokeMethod('enterPip');
      if (mounted && ok == true) {
        setState(() => _inPip = true);
      }
    } catch (_) {
      // Swallow; PiP might not be supported or OS denied it.
    }
  }

  Future<void> _refresh() async {
    _cover();
    try {
      await _controller.reload();
    } catch (_) {}
  }

  bool _isAllowedDestination(Uri dest) {
    // Allow only the exact same URL (hash changes ok), same origin required.
    if (dest.scheme != _allowedUri.scheme || dest.host != _allowedUri.host || dest.port != _allowedUri.port) {
      return false; // different origin
    }
    final String baseAllowed = _allowedUri.replace(fragment: null).toString();
    final String baseDest = dest.replace(fragment: null).toString();
    return baseDest == baseAllowed;
  }

  @override
  void dispose() {
    // Disable auto-PiP when leaving this screen
    _pip.invokeMethod('setAutoPipOnUserLeave', <String, dynamic>{'enabled': false}).catchError((_) {});
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // ——— Lifecycle: jump-to-live only for true app-resume, not rotation or PiP restore.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appState = state; // track current
    if (state == AppLifecycleState.paused) {
      _wentBackground = true;
    }
    if (state == AppLifecycleState.resumed && mounted) {
      if (!_wentBackground) return; // not a real background-resume
      _wentBackground = false;

      final DateTime now = DateTime.now();

      // Rotation heuristic: only true if we very recently *changed orientation*.
      final bool likelyRotation = _lastOrientationChangeAt != null && now.difference(_lastOrientationChangeAt!).inMilliseconds <= 900;

      // Heuristic: if resume is very close to exiting PiP, it's PiP restore
      final bool justLeftPip = _lastPipExitAt != null && now.difference(_lastPipExitAt!).inMilliseconds <= 1000;

      if (likelyRotation || justLeftPip || _inPip) return;

      _jumpToLive();
    }
  }

  Future<void> _jumpToLive() async {
    const String js = r'''
      (function(){
        let jumped = false;
        const vids = Array.from(document.querySelectorAll('video'));
        for (const v of vids) {
          try {
          // Unmute & ensure playing
            v.muted = v.muted || false;
          // If there is a seekable live window, jump to its end (live edge)
            if (v.seekable && v.seekable.length > 0) {
              const end = v.seekable.end(v.seekable.length - 1);
            // Nudge slightly behind the absolute edge to avoid stalling
              v.currentTime = Math.max(0, end - 1.0);
              v.play().catch(()=>{});
              jumped = true;
            } else if (v.buffered && v.buffered.length > 0) {
            // Fallback to the end of buffered range
              const end = v.buffered.end(v.buffered.length - 1);
              v.currentTime = Math.max(0, end - 0.5);
              v.play().catch(()=>{});
              jumped = true;
            } else {
            // As a last-ditch attempt, try play (some players re-sync on play)
              v.play().catch(()=>{});
            }
          } catch (e) {}
        }
        return jumped;
      })();
    ''';

    try {
      final Object res = await _controller.runJavaScriptReturningResult(js);
      final bool jumped = res == true;
      if (!jumped) {
        // If the page didn't expose seekable ranges, refresh to reattach at live
        await _controller.reload();
      }
    } catch (_) {
      // If JS failed (cross-origin restrictions, etc.), just reload
      try {
        await _controller.reload();
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    // Only record orientation changes when we're truly resumed and not in PiP,
    // and not currently suppressing due to a PiP transition.
    if (_appState == AppLifecycleState.resumed && !_inPip && !_suppressOrientationMarking) {
      final Orientation current = MediaQuery.of(context).orientation;
      if (_lastOrientation == null) {
        _lastOrientation = current;
      } else if (_lastOrientation != current) {
        _lastOrientation = current;
        _lastOrientationChangeAt = DateTime.now();
      }
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.black,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          top: false,
          bottom: false,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              const SizedBox.expand(child: _WebViewHolder()),
              if (_failed)
                ColoredBox(
                  color: Colors.black,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        const Icon(Icons.videocam_off, color: Colors.white54, size: 40),
                        const SizedBox(height: 12),
                        const Text(
                          'This stream is unavailable.',
                          style: TextStyle(color: Colors.white),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Try another stream or source.',
                          style: TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                        const SizedBox(height: 16),
                        TextButton(onPressed: _refresh, child: const Text('Retry')),
                      ],
                    ),
                  ),
                )
              else if (!_ready)
                const ColoredBox(
                  color: Colors.black,
                  child: Center(child: CircularProgressIndicator(color: Colors.white)),
                ),
            ],
          ),
        ),
        floatingActionButton: _inPip
            ? null
            : SpeedDial(
                icon: Icons.menu,
                foregroundColor: Colors.white,
                backgroundColor: Colors.black,
                overlayOpacity: 0.0,
                buttonSize: const Size(40, 40),
                childrenButtonSize: const Size(40, 40),
                childPadding: const EdgeInsets.all(0),
                spaceBetweenChildren: 5,
                children: [
                  SpeedDialChild(
                    shape: const CircleBorder(),
                    child: Center(
                      child: Icon(_muted ? Icons.volume_off : Icons.volume_up, color: Colors.white, size: 18),
                    ),
                    backgroundColor: Colors.black,
                    onTap: _toggleMute,
                  ),
                  SpeedDialChild(
                    shape: const CircleBorder(),
                    child: const Center(child: Icon(Icons.picture_in_picture, color: Colors.white, size: 15)),
                    backgroundColor: Colors.black,
                    onTap: _enterPip,
                  ),
                  SpeedDialChild(
                    shape: const CircleBorder(),
                    child: const Center(child: Icon(Icons.refresh, color: Colors.white, size: 18)),
                    backgroundColor: Colors.black,
                    onTap: () async {
                      await _refresh();
                    },
                  ),
                ],
              ),
      ),
    );
  }
}

// Simple holder so Scaffold rebuilds don’t recreate controller widget unnecessarily
class _WebViewHolder extends StatelessWidget {
  const _WebViewHolder();

  @override
  Widget build(BuildContext context) {
    // This widget is intentionally empty; the actual WebView is inserted by the parent state.
    // But WebViewWidget must still be in the tree, so we find the state's controller via context.
    final _StreamPlayerScreenState? s = context.findAncestorStateOfType<_StreamPlayerScreenState>();
    return s == null ? const SizedBox.shrink() : WebViewWidget(controller: s._controller);
  }
}

Map<String, String> sourceSubtitles = {
  'admin': 'Admin added streams',
  'alpha': 'Most reliable (720p 30fps)',
  'charlie': 'Good backup (poor quality occasionally)',
  'delta': 'Okayish backup (can lag/not load)',
  'echo': 'Great quality overall',
  'foxtrot': 'Good quality, offers home/away feeds',
  'golf': 'Third party (more ads), but very stable',
  'intel': 'Large event coverage, iffy quality',
};
