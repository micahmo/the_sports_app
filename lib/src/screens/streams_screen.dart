import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // For PiP state updates from native
    _pip.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'pipChanged') {
        final Object? args = call.arguments;
        final bool inPip = (args is Map && args['inPip'] is bool) ? args['inPip'] as bool : false;
        if (mounted) setState(() => _inPip = inPip);
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

    _controller = WebViewController()
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
          onPageFinished: (String _) {
            _injectGuards();
          },
          onWebResourceError: (WebResourceError error) {
            // Optional: show a snackbar/toast/retry
          },
        ),
      )
      ..loadRequest(_allowedUri);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Optional: auto-enter PiP when user backgrounds the app.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      _enterPip(); // comment out if you only want manual PiP via button
    }
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

  Future<void> _injectGuards() async {
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

          // Also block same-origin but different path (only allow same URL/hash)
          const noHashCurrent = new URL(location.href);
          noHashCurrent.hash = '';
          const noHashDest = new URL(dest.href);
          noHashDest.hash = '';
          if (noHashDest.href !== noHashCurrent.href) {
            e.preventDefault(); e.stopPropagation(); return false;
          }
          return true;
        }, true);
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
    } catch (_) {
      // No-op on platforms without the method.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Hide AppBar entirely while in PiP so only the video is visible
      appBar: _inPip
          ? null
          : AppBar(
              title: Text('Playing ${widget.title}'),
              actions: <Widget>[IconButton(tooltip: 'Picture-in-Picture', icon: const Icon(Icons.picture_in_picture_alt), onPressed: _enterPip)],
            ),
      // Remove padding when in PiP for a clean, edge-to-edge video
      body: _inPip ? WebViewWidget(controller: _controller) : SafeArea(child: WebViewWidget(controller: _controller)),
    );
  }
}
