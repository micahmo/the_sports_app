import '../generated/app_data.dart' show sportDisplayNames;

class Sport {
  final String id;
  final String name;
  Sport({required this.id, required this.name});
  factory Sport.fromJson(Map<String, dynamic> j) {
    final String id = j['id'] as String;
    // Names as North Americans say them (Soccer, Football); the ids, which
    // requests and icons use, stay as the API has them.
    return Sport(id: id, name: sportDisplayNames[id] ?? j['name'] as String);
  }
}

class TeamInfo {
  final String name;
  final String? badge; // id used in images endpoint
  TeamInfo({required this.name, required this.badge});
  factory TeamInfo.fromJson(Map<String, dynamic> j) => TeamInfo(name: j['name'] as String, badge: j['badge'] as String?);
}

class MatchTeams {
  final TeamInfo? home;
  final TeamInfo? away;
  MatchTeams({this.home, this.away});
  factory MatchTeams.fromJson(Map<String, dynamic> j) => MatchTeams(home: j['home'] != null ? TeamInfo.fromJson(j['home']) : null, away: j['away'] != null ? TeamInfo.fromJson(j['away']) : null);
}

class MatchSourceRef {
  final String source; // e.g. alpha, bravo
  final String id; // source-specific match id
  MatchSourceRef({required this.source, required this.id});
  factory MatchSourceRef.fromJson(Map<String, dynamic> j) => MatchSourceRef(source: j['source'] as String, id: j['id'] as String);
}

class ApiMatch {
  final String id;
  final String title;
  final String category;
  final int date; // unix ms
  final String? poster; // url path (prefix with https://streamed.pk if starts with '/')
  final bool? popular;
  final MatchTeams? teams;
  final List<MatchSourceRef> sources;

  /// Total viewers across the match's streams. Only /api/matches/live/popular-viewcount
  /// returns this, and only for the handful of biggest live matches, so it is
  /// null for most matches.
  final int? viewers;

  ApiMatch({required this.id, required this.title, required this.category, required this.date, required this.popular, required this.sources, this.poster, this.teams, this.viewers});
  factory ApiMatch.fromJson(Map<String, dynamic> j) => ApiMatch(
    id: j['id'] as String,
    title: j['title'] as String,
    category: j['category'] as String,
    date: (j['date'] as num).toInt(),
    poster: j['poster'] as String?,
    popular: j['popular'] as bool?,
    teams: j['teams'] != null ? MatchTeams.fromJson(j['teams']) : null,
    sources: ((j['sources'] as List<dynamic>).map((e) => MatchSourceRef.fromJson(e))).toList(),
    viewers: (j['viewers'] as num?)?.toInt(),
  );

  ApiMatch withViewers(int? v) => ApiMatch(
    id: id,
    title: title,
    category: category,
    date: date,
    popular: popular,
    sources: sources,
    poster: poster,
    teams: teams,
    viewers: v,
  );
}

class StreamInfo {
  final String id;
  final int streamNo;
  final String language;
  final bool hd;
  final String embedUrl;
  final String source;

  /// Undocumented — it is not in the published Stream interface, but every
  /// stream row currently carries it. Treated as optional in case it goes away.
  final int? viewers;

  StreamInfo({required this.id, required this.streamNo, required this.language, required this.hd, required this.embedUrl, required this.source, this.viewers});
  factory StreamInfo.fromJson(Map<String, dynamic> j) => StreamInfo(
    id: j['id'] as String,
    streamNo: (j['streamNo'] as num).toInt(),
    language: j['language'] as String,
    hd: j['hd'] as bool,
    embedUrl: j['embedUrl'] as String,
    source: j['source'] as String,
    viewers: (j['viewers'] as num?)?.toInt(),
  );
}

enum Mode { bySport, live, livePopular, liveFavorites }

/// Compact viewer counts, e.g. 249 -> "249", 1584 -> "1.6k", 33814 -> "34k".
String formatViewers(int n) {
  if (n < 1000) return '$n';
  final double k = n / 1000;
  return k < 10 ? '${k.toStringAsFixed(1)}k' : '${k.round()}k';
}
