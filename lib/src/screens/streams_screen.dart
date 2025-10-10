import 'package:flutter/material.dart';
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
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => StreamPlayerScreen(stream: s))),
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

class StreamPlayerScreen extends StatefulWidget {
  const StreamPlayerScreen({super.key, required this.stream});
  final StreamInfo stream;

  @override
  State<StreamPlayerScreen> createState() => _StreamPlayerScreenState();
}

class _StreamPlayerScreenState extends State<StreamPlayerScreen> {
  late final Uri _allowedUri;
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();
    _allowedUri = Uri.parse(widget.stream.embedUrl);

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
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
              // Snap back if something changed the URL (pushState/redirect).
              _controller.loadRequest(_allowedUri);
            }
          },
          onPageFinished: (String url) {
            // Re-inject guards after each successful load.
            _injectGuards();
          },
          onWebResourceError: (WebResourceError error) {
            // Optional: surface a toast/snackbar or retry UI.
          },
        ),
      )
      ..loadRequest(_allowedUri);
  }

  bool _isAllowedDestination(Uri dest) {
    // Only allow the exact same URL, or same URL with a hash fragment change.
    if (dest.scheme != _allowedUri.scheme || dest.host != _allowedUri.host || dest.port != _allowedUri.port) {
      return false; // different origin
    }
    final String baseAllowed = _allowedUri.replace(fragment: null).toString();
    final String baseDest = dest.replace(fragment: null).toString();
    return baseDest == baseAllowed;
  }

  Future<void> _injectGuards() async {
    // Disable popups and block off-origin or path-changing links.
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
      // Ignore benign errors from sandboxed pages.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Playing #${widget.stream.streamNo}')),
      body: WebViewWidget(controller: _controller),
    );
  }
}
