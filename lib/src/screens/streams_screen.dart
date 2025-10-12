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
  bool _isFullscreen = false;

  DateTime? _lastMetricsChangeAt;
  DateTime? _lastPipExitAt;
  bool _wentBackground = false;

  @override
  void initState() {
    super.initState();

    // For PiP state updates from native
    _pip.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'pipChanged') {
        final Object? args = call.arguments;
        final bool inPip = (args is Map && args['inPip'] is bool) ? args['inPip'] as bool : false;
        if (mounted) setState(() => _inPip = inPip);
        if (!inPip) {
          _lastPipExitAt = DateTime.now(); // mark PiP exit moment
        }
      }
      return null;
    });

    // Initialize current PiP state (best-effort)
    _pip
        .invokeMethod('isInPip')
        .then((dynamic v) {
          if (mounted) setState(() => _inPip = (v == true));
        })
        .catchError((_) {});

    _allowedUri = Uri.parse(widget.stream.embedUrl);

    // --- Build controller with Android-specific autoplay setting ---
    const PlatformWebViewControllerCreationParams params = PlatformWebViewControllerCreationParams();

    final WebViewController controller = WebViewController.fromPlatformCreationParams(params)
      ..addJavaScriptChannel(
        'Fullscreen', // this becomes a JS object `Fullscreen.postMessage('...')`
        onMessageReceived: (JavaScriptMessage m) {
          final String msg = m.message;
          if (msg == 'enter' || msg == 'exit') {
            setState(() {
              _isFullscreen = (msg == 'enter');
            });
          }
        },
      )
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
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
          onWebResourceError: (WebResourceError error) {
            // Optional: show a snackbar/toast/retry
          },
        ),
      );

    // ANDROID: allow media to start without a user gesture
    if (controller.platform is AndroidWebViewController) {
      final AndroidWebViewController a = controller.platform as AndroidWebViewController;
      a.setMediaPlaybackRequiresUserGesture(false);
    }

    _controller = controller..loadRequest(_allowedUri);

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

        // Notify Flutter when the page enters/exits fullscreen
        (function(){
          function notify() {
            try {
              // If any element is fullscreen, send 'enter', else 'exit'
              Fullscreen.postMessage(document.fullscreenElement ? 'enter' : 'exit');
            } catch (e) {}
          }
          document.addEventListener('fullscreenchange', notify, true);
          document.addEventListener('webkitfullscreenchange', notify, true);
          document.addEventListener('mozfullscreenchange', notify, true);
          document.addEventListener('MSFullscreenChange', notify, true);

          // Some players use video-specific events (rare on Android, but safe)
          const vids = Array.from(document.querySelectorAll('video'));
          for (const v of vids) {
            v.addEventListener('fullscreenchange', notify, true);
            v.addEventListener('webkitbeginfullscreen', () => Fullscreen.postMessage('enter'), true);
            v.addEventListener('webkitendfullscreen', () => Fullscreen.postMessage('exit'), true);
          }
          // Initial fire (in case the embed was already fullscreen)
          notify();
        })();
      } catch (_) {}
      true;
    ''';
    try {
      await _controller.runJavaScriptReturningResult(js);
    } catch (_) {
      // Ignore script errors from restrictive embeds.
    }
  }

  Future<void> _enterPip({int width = 16, int height = 9}) async {
    try {
      await _pip.invokeMethod('enterPip', <String, dynamic>{'width': width, 'height': height});
    } catch (_) {}
  }

  Future<void> _refresh() async {
    try {
      await _controller.reload();
    } catch (_) {
      // fallback if reload not supported
      await _controller.loadRequest(_allowedUri);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Hide AppBar entirely while in PiP so only the video is visible
      appBar: _inPip
          ? PreferredSize(
              // keep layout stable
              preferredSize: const Size.fromHeight(0),
              child: AppBar(
                // still mounted, zero height
                elevation: 0,
                toolbarHeight: 0,
                backgroundColor: Colors.black,
              ),
            )
          : AppBar(
              title: Text(widget.title),
              actions: [
                IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _refresh),
                IconButton(tooltip: 'Picture-in-Picture', icon: const Icon(Icons.picture_in_picture_alt), onPressed: _enterPip),
              ],
            ),
      // Remove padding when in PiP for a clean, edge-to-edge video
      backgroundColor: Colors.black,
      body: Container(
        color: Colors.black,
        child: Column(
          children: [
            // Reserve space equal to the top padding only when NOT in PiP
            // (so top inset change is gradual and controlled)
            AnimatedContainer(duration: const Duration(milliseconds: 150), height: _inPip ? 0 : MediaQuery.of(context).padding.top),
            // The player area remains constant height fraction; tweak as you like
            Expanded(child: WebViewWidget(controller: _controller)),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _wentBackground = true;
    }
    if (state == AppLifecycleState.resumed && mounted) {
      // Only consider jump if we truly came from background
      if (!_wentBackground) return;

      final DateTime now = DateTime.now();

      // Heuristic: if resume is very close to a metrics change, it's rotation
      final bool likelyRotation = _lastMetricsChangeAt != null && now.difference(_lastMetricsChangeAt!).inMilliseconds <= 600;

      // Heuristic: if resume is very close to exiting PiP, it's PiP restore
      final bool justLeftPip = _lastPipExitAt != null && now.difference(_lastPipExitAt!).inMilliseconds <= 1000;

      // Reset flag—this resume handled
      _wentBackground = false;

      if (likelyRotation || justLeftPip || _inPip) {
        // Skip jump-to-live in these cases
        return;
      }

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
      final bool jumped = res == true; // webview_flutter returns bool as true/false
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
  void didChangeMetrics() {
    _lastMetricsChangeAt = DateTime.now();
  }
}
