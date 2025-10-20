import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_speed_dial/flutter_speed_dial.dart';
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
                return _SourceHeader(source: e.source);
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
  const _SourceHeader({required this.source});
  final String source;

  @override
  Widget build(BuildContext context) {
    final TextTheme t = Theme.of(context).textTheme;
    return Container(
      color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Text(source, style: t.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
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
      ..setNavigationDelegate(
        NavigationDelegate(
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
          onPageFinished: (String _) => _injectGuardsAndAutoplay(),
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

  Future<void> _injectGuardsAndAutoplay() async {
    const String js = r'''
(() => {
  try {
    // Disable window.open to avoid external popouts
    window.open = function(){ return null; };

    // Intercept link clicks (capture phase) and block cross-origin
    document.addEventListener('click', function(e){
      const a = e.target && e.target.closest ? e.target.closest('a') : null;
      if (!a || !a.href) return;
      const dest = new URL(a.href, location.href);
      if (dest.origin !== location.origin) {
        e.preventDefault(); e.stopPropagation(); return false;
      }
      return true;
    }, true);

    if (!window.__autoplayAgentInstalled) {
      window.__autoplayAgentInstalled = true;

      // Track any WebAudio contexts so we can resume them after a gesture.
      window.__audioContexts = [];
      const _AC = window.AudioContext || window.webkitAudioContext;
      if (_AC) {
        const OrigAC = _AC;
        const wrap = function(...args) {
          const ctx = new OrigAC(...args);
          try { window.__audioContexts.push(ctx); } catch(e) {}
          return ctx;
        };
        wrap.prototype = OrigAC.prototype;
        if (window.AudioContext) window.AudioContext = wrap;
        if (window.webkitAudioContext) window.webkitAudioContext = wrap;
      }

      // Helper: unmute all HTML5 videos and resume WebAudio.
      window.__unmuteAllVideos = () => {
        try {
          const vids = Array.from(document.querySelectorAll('video'));
          for (const v of vids) {
            try {
              v.muted = false;
              // volume can be clamped by sites, but try to set it anyway
              v.volume = 1.0;
              v.play && v.play().catch(()=>{});
            } catch(e) {}
          }
        } catch(e) {}
        try {
          for (const ctx of (window.__audioContexts || [])) {
            if (ctx && ctx.state === 'suspended') {
              ctx.resume().catch(()=>{});
            }
          }
        } catch(e) {}
        return true;
      };

      // Core attempt logic: make a specific video play as soon as possible (muted).
      const tryPlayVideo = (v) => {
        if (!v) return;

      // Mobile-friendly flags
        v.muted = true;                 // allow autoplay
      v.playsInline = true;           // iOS/WebKit hint (no harm on Android)
        v.setAttribute('playsinline', '');
        v.autoplay = true;

        const attempt = () => {
        // If there's a seekable live edge, nudge to the end to avoid stalling
          try {
            if (v.seekable && v.seekable.length > 0) {
              const end = v.seekable.end(v.seekable.length - 1);
            // Stay just behind edge
              if (!Number.isNaN(end) && end > 0) v.currentTime = Math.max(0, end - 1.0);
            }
          } catch (e) {}

        v.play().catch(() => { /* ignore */ });
        };

      // If already ready enough, try immediately
      if (v.readyState >= 2 /* HAVE_CURRENT_DATA */) {
          attempt();
        } else {
        // Otherwise wait for readiness, then try
          const onReady = () => { v.removeEventListener('loadedmetadata', onReady); v.removeEventListener('canplay', onReady); attempt(); };
          v.addEventListener('loadedmetadata', onReady, { once: true });
          v.addEventListener('canplay', onReady, { once: true });

        // Also try a gentle kick after microtask in case readyState just flipped
          Promise.resolve().then(attempt);
        }
      };

      // Sweep any existing videos now
      Array.from(document.querySelectorAll('video')).forEach(tryPlayVideo);

      // Watch for newly inserted videos or player re-renders
      const mo = new MutationObserver((mutations) => {
        for (const m of mutations) {
          for (const node of m.addedNodes) {
            if (!(node instanceof Element)) continue;
          if (node.tagName && node.tagName.toLowerCase() === 'video') {
            tryPlayVideo(node);
          }
          // In case a <div> contains nested <video>
            const vids = node.querySelectorAll ? node.querySelectorAll('video') : [];
            vids && vids.forEach(tryPlayVideo);
          }
        }
      });
      mo.observe(document.documentElement, { childList: true, subtree: true });

    // Fallbacks for late-ready pages
      const kick = () => Array.from(document.querySelectorAll('video')).forEach(tryPlayVideo);
    // DOM ready changes (rare, but cheap)
      document.addEventListener('readystatechange', kick, { passive: true });
    // Final onload
      window.addEventListener('load', kick, { passive: true });

      // 👇 First real user gesture inside the page -> unmute everything
      const autoUnmuteOnce = (ev) => {
        try { window.__unmuteAllVideos && window.__unmuteAllVideos(); } catch(e) {}
        document.removeEventListener('pointerdown', autoUnmuteOnce, true);
        document.removeEventListener('keydown', autoUnmuteOnce, true);
      };
      document.addEventListener('pointerdown', autoUnmuteOnce, true);
      document.addEventListener('keydown', autoUnmuteOnce, true);
    }
  } catch (e) {}
  return true;
})();
''';

    try {
      await _controller.runJavaScriptReturningResult(js);
    } catch (_) {}
  }

  Future<void> _unmuteAndPlay() async {
    const String js = r'''
    (function(){
      try { return window.__unmuteAllVideos ? window.__unmuteAllVideos() : false; }
      catch(e) { return false; }
    })();
  ''';
    try {
      await _controller.runJavaScriptReturningResult(js);
    } catch (_) {}
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
        body: const SafeArea(top: false, bottom: false, child: SizedBox.expand(child: _WebViewHolder())),
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
                  // Uncomment this to add an unmute button
                  // SpeedDialChild(
                  //   shape: const CircleBorder(),
                  //   child: const Center(child: Icon(Icons.volume_up, color: Colors.white, size: 18)),
                  //   backgroundColor: Colors.black,
                  //   onTap: _unmuteAndPlay,
                  // ),
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
                      await _unmuteAndPlay();
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
