import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import '../api/models.dart';
import '../api/streamed_api.dart';

class StreamsScreen extends StatefulWidget {
  const StreamsScreen({super.key, required this.matchItem});
  final ApiMatch matchItem;

  @override
  State<StreamsScreen> createState() => _StreamsScreenState();
}

class _StreamsScreenState extends State<StreamsScreen> {
  final StreamedApi _api = StreamedApi();
  late Future<List<StreamInfo>> _future;

  @override
  void initState() {
    super.initState();
    // Choose first available source from the match (user can pick later too)
    // We’ll fetch all streams for the first source initially.
    final MatchSourceRef initial = widget.matchItem.sources.first;
    _future = _api.fetchStreams(initial.source, initial.id);
  }

  @override
  Widget build(BuildContext context) {
    final String title = widget.matchItem.title;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Column(
        children: <Widget>[
          _SourcesChips(
            matchItem: widget.matchItem,
            onPick: (MatchSourceRef s) {
              setState(() {
                _future = _api.fetchStreams(s.source, s.id);
              });
            },
          ),
          const Divider(height: 1),
          Expanded(
            child: FutureBuilder<List<StreamInfo>>(
              future: _future,
              builder: (BuildContext ctx, AsyncSnapshot<List<StreamInfo>> snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return Center(child: Text('Error: ${snap.error}'));
                }
                final List<StreamInfo> streams = snap.data ?? <StreamInfo>[];
                if (streams.isEmpty) {
                  return const Center(child: Text('No streams available for this source.'));
                }
                return ListView.builder(
                  itemCount: streams.length,
                  itemBuilder: (_, int i) {
                    final StreamInfo s = streams[i];
                    return ListTile(
                      leading: Icon(s.hd ? Icons.hd : Icons.sd),
                      title: Text('Stream #${s.streamNo}${s.language.isEmpty ? '' : ' • ${s.language}'}'),
                      subtitle: Text('Source: ${s.source}'),
                      trailing: const Icon(Icons.play_arrow),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => StreamPlayerScreen(stream: s, title: title),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SourcesChips extends StatelessWidget {
  const _SourcesChips({required this.matchItem, required this.onPick});
  final ApiMatch matchItem;
  final void Function(MatchSourceRef) onPick;

  @override
  Widget build(BuildContext context) {
    final List<MatchSourceRef> sources = matchItem.sources;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(8),
      child: Row(
        children: sources.map((MatchSourceRef s) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ActionChip(label: Text(s.source), onPressed: () => onPick(s)),
          );
        }).toList(),
      ),
    );
  }
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

  DateTime? _lastMetricsChangeAt;
  DateTime? _lastPipExitAt;
  bool _wentBackground = false;

  @override
  void initState() {
    super.initState();

    // Tell native: auto-PiP when user leaves app (Home/Recents) for THIS screen.
    _pip.invokeMethod('setAutoPipOnUserLeave', <String, dynamic>{'enabled': true}).catchError((_) {});

    // PiP state updates
    _pip.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'pipChanged') {
        final Object? args = call.arguments;
        final bool inPip = (args is Map && args['inPip'] is bool) ? args['inPip'] as bool : false;
        if (mounted) setState(() => _inPip = inPip);
        if (!inPip) _lastPipExitAt = DateTime.now();
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
      try {
        // Disable window.open
        window.open = function(){ return null; };

        // Intercept link clicks (capture phase)
        document.addEventListener('click', function(e){
          const a = e.target && e.target.closest ? e.target.closest('a') : null;
          if (!a || !a.href) return;
          const dest = new URL(a.href, location.href);

          // Block different origin outright
          if (dest.origin !== location.origin) {
            e.preventDefault(); e.stopPropagation(); return false;
          }

          // Same-origin links are allowed (player may need them)
          return true;
        }, true);

        // Try muted autoplay for any <video> tags on the page (Android-friendly)
        (async () => {
          const vids = Array.from(document.querySelectorAll('video'));
          for (const v of vids) {
            try {
              if (v.paused) {
                v.muted = true;
                await v.play();
              }
            } catch (e) {}
          }
        })();
      } catch (_) {}
      true;
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
    if (state == AppLifecycleState.paused) {
      _wentBackground = true;
    }
    if (state == AppLifecycleState.resumed && mounted) {
      if (!_wentBackground) return; // not a real background-resume
      _wentBackground = false;

      final DateTime now = DateTime.now();

      // Heuristic: if resume is very close to a metrics change, it's rotation
      final bool likelyRotation = _lastMetricsChangeAt != null && now.difference(_lastMetricsChangeAt!).inMilliseconds <= 600;

      // Heuristic: if resume is very close to exiting PiP, it's PiP restore
      final bool justLeftPip = _lastPipExitAt != null && now.difference(_lastPipExitAt!).inMilliseconds <= 1000;

      if (likelyRotation || justLeftPip || _inPip) return;

      _jumpToLive();
    }
  }

  @override
  void didChangeMetrics() {
    _lastMetricsChangeAt = DateTime.now();
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
        body: const SafeArea(
          top: false, // truly edge-to-edge
          bottom: false,
          child: SizedBox.expand(
            child: _WebViewHolder(), // we’ll insert via Inherited to keep widget tree simple
          ),
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
    return s == null ? SizedBox.shrink() : WebViewWidget(controller: s._controller);
  }
}
