import 'dart:convert';
import 'package:http/http.dart' as http;
import '../generated/app_data.dart' show BackendConfig, sportDisplayNames;
import 'backend.dart';
import 'models.dart';

// ppv.st (see DESIGN_NOTES, Backends). One request lists every event by
// category, so it's kept a minute and every list is answered from it.
class PpvBackend extends Backend {
  final http.Client _client = http.Client();
  PpvSnapshot? _last;
  DateTime? _lastAt;
  Future<PpvSnapshot>? _pending;

  Future<PpvSnapshot> _snapshot() {
    final PpvSnapshot? last = _last;
    if (last != null && DateTime.now().difference(_lastAt!) < const Duration(minutes: 1)) return Future<PpvSnapshot>.value(last);
    return _pending ??= _fetch().whenComplete(() => _pending = null);
  }

  Future<PpvSnapshot> _fetch() async {
    final http.Response r = await _client.get(Uri.parse(BackendConfig.api), headers: <String, String>{'User-Agent': Backend.browserAgent});
    Backend.ensureOk(r);
    final PpvSnapshot s = parse(jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>);
    _last = s;
    _lastAt = DateTime.now();
    return s;
  }

  /// The site's answer in the app's models. Public for the shared fixtures'
  /// test (shared/fixtures/ppv).
  static PpvSnapshot parse(Map<String, dynamic> body) {
    final List<Sport> sports = <Sport>[];
    final List<ApiMatch> matches = <ApiMatch>[];
    final Map<String, List<StreamInfo>> streams = <String, List<StreamInfo>>{};
    final Set<String> live = <String>{};
    final int now = ((body['timestamp'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch ~/ 1000);
    for (final dynamic c in body['streams'] as List<dynamic>) {
      final Map<String, dynamic> cat = c as Map<String, dynamic>;
      final String catName = cat['category'] as String;
      final String sportId = sportIdFor(catName);
      final List<dynamic> events = cat['streams'] as List<dynamic>;
      if (events.isEmpty) continue;
      if (!sports.any((Sport s) => s.id == sportId)) sports.add(Sport(id: sportId, name: sportDisplayNames[sportId] ?? catName));
      for (final dynamic e in events) {
        final Map<String, dynamic> ev = e as Map<String, dynamic>;
        final String id = '${ev['id']}';
        final bool always = (ev['always_live'] as num? ?? 0) != 0;
        final int starts = (ev['starts_at'] as num? ?? 0).toInt();
        final int ends = (ev['ends_at'] as num? ?? 0).toInt();
        final String title = (ev['name'] as String).trim();
        final bool isLive = always || (starts <= now && (ends == 0 || now < ends));
        // The site counts people waiting for a game too, before it starts.
        final int? viewers = int.tryParse('${ev['viewers'] ?? ''}');
        final String? poster = ev['poster'] as String?;
        matches.add(ApiMatch(
          id: id,
          title: title,
          category: sportId,
          // 0: a 24/7 channel, as the app has always read it.
          date: always ? 0 : starts * 1000,
          poster: poster,
          // The poster's a 300x168 thumbnail; without "-thumbnail", the
          // full picture (1280x720 mostly, 2026-10-28).
          backdrop: poster != null && poster.contains('-thumbnail.') ? poster.replaceFirst('-thumbnail.', '.') : null,
          popular: null,
          teams: teamsFrom(title, poster),
          sources: <MatchSourceRef>[MatchSourceRef(source: 'ppv', id: id)],
          viewers: viewers,
        ));
        if (isLive) live.add(id);
        // The event's own feed, then its other feeds (other broadcasters,
        // languages), each named by broadcaster.
        final List<StreamInfo> list = <StreamInfo>[];
        void add(Map<String, dynamic> f, int? v) {
          final String source = ((f['source_tag'] as String?) ?? '').trim();
          final String name = source.isEmpty ? 'Stream' : source;
          final int no = list.where((StreamInfo s) => s.source == name).length + 1;
          list.add(StreamInfo(
            id: '${f['id']}',
            streamNo: no,
            language: languageName(f['locale'] as String?),
            hd: true,
            embedUrl: f['iframe'] as String,
            source: name,
            viewers: v,
          ));
        }

        add(ev, viewers);
        for (final dynamic sub in (ev['substreams'] as List<dynamic>? ?? <dynamic>[])) {
          add(sub as Map<String, dynamic>, null);
        }
        streams[id] = list;
      }
    }
    return PpvSnapshot(sports, matches, streams, live);
  }

  /// Our sport id for the site's category name (shared/app_data.json); else
  /// the name itself, lowercased with dashes, which shows with the default
  /// icon under its own name.
  static String sportIdFor(String category) =>
      BackendConfig.sportIds[category] ?? category.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-|-$'), '');

  /// The two sides of "A vs B" (home first) or "A at B" (away first), for the
  /// cards' team lines, with their logos from the poster (the first-named
  /// team's on the left); null for anything else (channels, events).
  static MatchTeams? teamsFrom(String title, String? poster) {
    final List<String?> logos = Backend.posterLogos(poster);
    final RegExpMatch? at = RegExp(r'^(.+?)\s+at\s+(.+)$').firstMatch(title);
    if (at != null) return MatchTeams(home: TeamInfo(name: at.group(2)!.trim(), badge: logos[1]), away: TeamInfo(name: at.group(1)!.trim(), badge: logos[0]));
    final RegExpMatch? vs = RegExp(r'^(.+?)\s+(?:vs\.?|v)\s+(.+)$', caseSensitive: false).firstMatch(title);
    if (vs != null) return MatchTeams(home: TeamInfo(name: vs.group(1)!.trim(), badge: logos[0]), away: TeamInfo(name: vs.group(2)!.trim(), badge: logos[1]));
    return null;
  }

  static const Map<String, String> _languages = <String, String>{
    'en': 'English',
    'es': 'Spanish',
    'fr': 'French',
    'de': 'German',
    'it': 'Italian',
    'pt': 'Portuguese',
    'nl': 'Dutch',
    'sv': 'Swedish',
    'ar': 'Arabic',
  };

  /// "en-gb" -> "English"; an unknown code as it is.
  static String languageName(String? locale) {
    if (locale == null || locale.isEmpty) return '';
    return _languages[locale.split('-').first.toLowerCase()] ?? locale;
  }

  @override
  Future<List<Sport>> fetchSports() async => (await _snapshot()).sports;

  @override
  Future<List<ApiMatch>> fetchAllMatches() async => (await _snapshot()).matches;

  @override
  Future<List<ApiMatch>> fetchMatchesBySport(String sportId) async =>
      (await _snapshot()).matches.where((ApiMatch m) => m.category == sportId).toList();

  @override
  Future<List<ApiMatch>> fetchLiveMatches() async {
    final PpvSnapshot s = await _snapshot();
    return s.matches.where((ApiMatch m) => s.live.contains(m.id)).toList();
  }

  /// The site has no "popular" flag: live and watched.
  @override
  Future<List<ApiMatch>> fetchLivePopular() async => (await fetchLiveViewCounts()).where((ApiMatch m) => (m.viewers ?? 0) > 0).toList();

  @override
  Future<List<ApiMatch>> fetchLiveViewCounts() async {
    final List<ApiMatch> live = (await fetchLiveMatches()).where((ApiMatch m) => m.viewers != null).toList();
    live.sort((ApiMatch a, ApiMatch b) => b.viewers!.compareTo(a.viewers!));
    return live;
  }

  @override
  Future<List<StreamInfo>> fetchStreams(MatchSourceRef ref) async => (await _snapshot()).streams[ref.id] ?? <StreamInfo>[];

  @override
  String posterUrl(ApiMatch m) => m.poster ?? '';

  @override
  String? badgeUrl(String badgeId) => null;
}

class PpvSnapshot {
  final List<Sport> sports;
  final List<ApiMatch> matches;
  final Map<String, List<StreamInfo>> streams;
  final Set<String> live;
  PpvSnapshot(this.sports, this.matches, this.streams, this.live);
}
