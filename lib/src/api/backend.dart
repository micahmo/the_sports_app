import 'dart:convert';
import 'package:http/http.dart' as http;
import '../generated/app_data.dart' show BackendConfig, sourceOrder;
import 'models.dart';
import 'ppv_backend.dart';

// The site the app lists and plays from, behind one interface (see
// DESIGN_NOTES, Backends): an adapter per site turns its API into the app's
// models, and BackendConfig.name (shared/app_data.json) picks which.

/// Streams grouped by source in the backend's order (sourceOrder, from
/// shared/app_data.json); anything unknown sorts to the end, keeping its
/// relative order.
int sourceRank(String source) {
  final int i = sourceOrder.indexOf(source.toLowerCase());
  return i == -1 ? sourceOrder.length : i;
}

/// A badge's picture: [url], cut down to [crop] (left, top, width, height as
/// fractions of the picture) when the logo is part of a bigger one.
class BadgeImage {
  final String url;
  final List<double>? crop;
  const BadgeImage(this.url, [this.crop]);
}

abstract class Backend {
  /// The one in use.
  static final Backend current = _make(BackendConfig.name);

  static Backend _make(String name) {
    switch (name) {
      case 'ppv':
        return PpvBackend();
    }
    throw StateError('No adapter for backend "$name"');
  }

  /// Saved data (recents, remembered quality, failed marks) is kept per
  /// backend: a switch starts it afresh instead of offering the old site's
  /// matches and links.
  static String savedKey(String key) => '$key.${BackendConfig.name}';

  Future<List<Sport>> fetchSports();
  Future<List<ApiMatch>> fetchMatchesBySport(String sportId);
  Future<List<ApiMatch>> fetchLiveMatches();
  Future<List<ApiMatch>> fetchLivePopular();

  /// Every match across every sport, 24/7 channels included.
  Future<List<ApiMatch>> fetchAllMatches();

  /// Live matches with a viewer count, most watched first.
  Future<List<ApiMatch>> fetchLiveViewCounts();

  /// The streams one of a match's sources has right now.
  Future<List<StreamInfo>> fetchStreams(MatchSourceRef ref);

  /// The match's poster image, or '' for none.
  String posterUrl(ApiMatch m);

  /// A team badge's image from the backend's own badge id, or null if this
  /// backend has none.
  String? badgeUrl(String badgeId);

  /// A team badge's image: the backend's own badge, or (`logo<n>:<poster>`,
  /// see [posterLogos]) the team's logo cut from the game's poster. Null for
  /// none.
  BadgeImage? badgeImage(String? badgeId) {
    if (badgeId == null || badgeId.isEmpty) return null;
    final RegExpMatch? logo = RegExp(r'^logo(\d+):(.+)$').firstMatch(badgeId);
    if (logo != null) {
      final int i = int.parse(logo.group(1)!);
      return i < BackendConfig.logoCrops.length ? BadgeImage(logo.group(2)!, BackendConfig.logoCrops[i]) : null;
    }
    final String? url = badgeUrl(badgeId);
    return url == null ? null : BadgeImage(url);
  }

  /// Badge ids for a game's two teams, in the order its title names them, for
  /// a site without team badges whose posters show both logos in the same
  /// places (BackendConfig.logoCrops); nulls without those.
  static List<String?> posterLogos(String? poster) {
    if (poster == null || poster.isEmpty || BackendConfig.logoCrops.length < 2) return <String?>[null, null];
    return <String?>['logo0:$poster', 'logo1:$poster'];
  }

  /// A game's sources from the live and full lists combined, or null if
  /// neither lists it. (On streamed.pk they disagreed, 2026-10-10: a working
  /// source shouldn't go missing because one list left it out.)
  Future<List<MatchSourceRef>?> currentSources(String matchId) async {
    final List<List<ApiMatch>> lists = await Future.wait(<Future<List<ApiMatch>>>[fetchLiveMatches(), fetchAllMatches()]);
    final List<ApiMatch> found = <ApiMatch>[for (final List<ApiMatch> l in lists) ...l.where((ApiMatch m) => m.id == matchId)];
    if (found.isEmpty) return null;
    return mergeSources(<List<MatchSourceRef>>[for (final ApiMatch m in found) m.sources]);
  }

  /// Each source once, as first seen.
  static List<MatchSourceRef> mergeSources(List<List<MatchSourceRef>> lists) {
    final Map<String, MatchSourceRef> byKey = <String, MatchSourceRef>{};
    for (final List<MatchSourceRef> l in lists) {
      for (final MatchSourceRef r in l) {
        byKey.putIfAbsent('${r.source}/${r.id}', () => r);
      }
    }
    return byKey.values.toList();
  }

  Future<List<StreamInfo>> fetchMatchStreams(ApiMatch m) => fetchSourcesStreams(m.sources);

  /// All of these sources' streams, best sources first (see [sourceRank]).
  /// Sources that fail or have nothing right now are left out.
  Future<List<StreamInfo>> fetchSourcesStreams(List<MatchSourceRef> refs) async {
    final List<MatchSourceRef> sources = List<MatchSourceRef>.of(refs);
    final List<int> order = List<int>.generate(sources.length, (int i) => i)
      ..sort((int a, int b) {
        final int byRank = sourceRank(sources[a].source).compareTo(sourceRank(sources[b].source));
        return byRank != 0 ? byRank : a.compareTo(b);
      });
    final List<List<StreamInfo>> results = await Future.wait(
      <Future<List<StreamInfo>>>[
        for (final int i in order) fetchStreams(sources[i]).catchError((Object _) => <StreamInfo>[]),
      ],
    );
    return <StreamInfo>[for (final List<StreamInfo> r in results) ...r];
  }

  /// The page to play when a stream's embed page puts its player in another
  /// site's frame: that page frames an ordinary player page of the embed's own
  /// site, its address in base64 (`atob("…")`). Opened directly, that page
  /// plays like any other (streamed.pk's golf source, 2026-09-30). The embed
  /// URL itself if anything along the way doesn't match. By what the page
  /// does, not the site's name. (The Roku does the same: playerPageUrl in
  /// roku/app/source/streamlink.brs.)
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

  static final http.Client _pages = http.Client();

  // Pages as a browser would ask for them (the sites answer a browser).
  static Future<String> _pageText(Uri url, String? referer) async {
    final http.Response r = await _pages
        .get(url, headers: <String, String>{'User-Agent': browserAgent, if (referer != null) 'Referer': referer})
        .timeout(const Duration(seconds: 8));
    ensureOk(r);
    return r.body;
  }

  static const String browserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36';

  // The first frame on a page that comes from another site (the page's own
  // /ad.html and the like don't count).
  static Uri? _foreignFrame(String html, Uri page) {
    for (final RegExpMatch m in RegExp(r'''<iframe[^>]*\bsrc=["']([^"']+)["']''').allMatches(html)) {
      final Uri? u = Uri.tryParse(m.group(1)!);
      if (u != null && u.hasScheme && u.host != page.host) return u;
    }
    return null;
  }

  static void ensureOk(http.Response r) {
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw Exception('HTTP ${r.statusCode}: ${r.body}');
    }
  }
}
