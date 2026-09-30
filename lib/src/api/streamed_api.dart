import 'dart:convert';
import 'package:http/http.dart' as http;
import '../generated/app_data.dart' show sourceOrder;
import 'models.dart';

// streamed.pk orders sources best-first rather than however the API returns
// them, and demotes the weaker ones. Mirror that order (sourceOrder, from
// shared/app_data.json; we show them all, since scrolling is cheaper than
// hiding). Anything unknown sorts to the end, keeping its relative order.
int sourceRank(String source) {
  final int i = sourceOrder.indexOf(source.toLowerCase());
  return i == -1 ? sourceOrder.length : i;
}

class StreamedApi {
  static const String base = 'https://streamed.pk';

  final http.Client _client = http.Client();

  Future<List<Sport>> fetchSports() async {
    final http.Response r = await _client.get(Uri.parse('$base/api/sports'));
    _ensureOk(r);
    final List<dynamic> arr = jsonDecode(r.body) as List<dynamic>;
    return arr.map((e) => Sport.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<ApiMatch>> fetchMatchesBySport(String sportId) async {
    final http.Response r = await _client.get(Uri.parse('$base/api/matches/$sportId'));
    _ensureOk(r);
    final List<dynamic> arr = jsonDecode(r.body) as List<dynamic>;
    return arr.map((e) => ApiMatch.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<ApiMatch>> fetchLiveMatches() async {
    final http.Response r = await _client.get(Uri.parse('$base/api/matches/live'));
    _ensureOk(r);
    final List<dynamic> arr = jsonDecode(r.body) as List<dynamic>;
    return arr.map((e) => ApiMatch.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<ApiMatch>> fetchLivePopular() async {
    final http.Response r = await _client.get(Uri.parse('$base/api/matches/live/popular'));
    _ensureOk(r);
    final List<dynamic> arr = jsonDecode(r.body) as List<dynamic>;
    return arr.map((e) => ApiMatch.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Every match across every sport. Undocumented sibling `all-today` claims to
  /// be today-only but returns exactly the same rows, so it is not used.
  Future<List<ApiMatch>> fetchAllMatches() async {
    final http.Response r = await _client.get(Uri.parse('$base/api/matches/all'));
    _ensureOk(r);
    final List<dynamic> arr = jsonDecode(r.body) as List<dynamic>;
    return arr.map((e) => ApiMatch.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Undocumented endpoint the website's home page uses. Same match shape plus a
  /// match-level `viewers` total, but only for the few biggest live matches.
  Future<List<ApiMatch>> fetchLiveViewCounts() async {
    final http.Response r = await _client.get(Uri.parse('$base/api/matches/live/popular-viewcount'));
    _ensureOk(r);
    final List<dynamic> arr = jsonDecode(r.body) as List<dynamic>;
    return arr.map((e) => ApiMatch.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<StreamInfo>> fetchStreams(String source, String id) async {
    final http.Response r = await _client.get(Uri.parse('$base/api/stream/$source/$id'));
    _ensureOk(r);
    final List<dynamic> arr = jsonDecode(r.body) as List<dynamic>;
    return arr.map((e) => StreamInfo.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// All of a match's streams, best sources first (see [sourceRank]). Sources
  /// that fail or have nothing right now are left out.
  Future<List<StreamInfo>> fetchMatchStreams(ApiMatch m) async {
    final List<MatchSourceRef> sources = List<MatchSourceRef>.of(m.sources);
    final List<int> order = List<int>.generate(sources.length, (int i) => i)
      ..sort((int a, int b) {
        final int byRank = sourceRank(sources[a].source).compareTo(sourceRank(sources[b].source));
        return byRank != 0 ? byRank : a.compareTo(b);
      });
    final List<List<StreamInfo>> results = await Future.wait(
      <Future<List<StreamInfo>>>[
        for (final int i in order) fetchStreams(sources[i].source, sources[i].id).catchError((Object _) => <StreamInfo>[]),
      ],
    );
    return <StreamInfo>[for (final List<StreamInfo> r in results) ...r];
  }

  /// The page to play for a stream of a nested source (golf; see
  /// `nestedSources`): its embed page frames another site's page, which frames
  /// an ordinary embed.st player page, its address in base64 (`atob("…")`).
  /// Opened directly, that page plays like any other source's. The embed URL
  /// itself if anything along the way doesn't match. (The Roku does the same:
  /// playerPageUrl in roku/app/source/streamlink.brs.)
  Future<String> innerPlayerUrl(String embedUrl) async {
    try {
      final Uri embed = Uri.parse(embedUrl);
      final Uri? middle = _foreignFrame(await _pageText(embed, null), embed);
      if (middle == null) return embedUrl;
      final String html = await _pageText(middle, embedUrl);
      final RegExpMatch? b64 = RegExp(r'''atob\(\s*["']([A-Za-z0-9+/=]+)["']''').firstMatch(html);
      final String inner = b64 == null ? '' : utf8.decode(base64.decode(b64.group(1)!));
      return inner.startsWith('https://${embed.host}/embed/') ? inner : embedUrl;
    } catch (_) {
      return embedUrl;
    }
  }

  // Pages as a browser would ask for them (the sites answer a browser).
  Future<String> _pageText(Uri url, String? referer) async {
    final http.Response r = await _client
        .get(url, headers: <String, String>{'User-Agent': _browserAgent, if (referer != null) 'Referer': referer})
        .timeout(const Duration(seconds: 8));
    _ensureOk(r);
    return r.body;
  }

  static const String _browserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36';

  // The first frame on a page that comes from another site (the page's own
  // /ad.html and the like don't count).
  static Uri? _foreignFrame(String html, Uri page) {
    for (final RegExpMatch m in RegExp(r'''<iframe[^>]*\bsrc=["']([^"']+)["']''').allMatches(html)) {
      final Uri? u = Uri.tryParse(m.group(1)!);
      if (u != null && u.hasScheme && u.host != page.host) return u;
    }
    return null;
  }

  static void _ensureOk(http.Response r) {
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw Exception('HTTP ${r.statusCode}: ${r.body}');
    }
  }

  static String badgeUrl(String badgeId) => '$base/api/images/badge/$badgeId.webp';

  static String posterUrlFromMatch(ApiMatch m) {
    // Docs show poster sometimes as a URL path like "/api/images/proxy/..."
    if (m.poster == null) return '';
    final String p = m.poster!;
    if (p.startsWith('http')) return p;
    if (p.startsWith('/')) return '$base$p.webp';
    return '$base/api/images/proxy/$p.webp';
  }
}
