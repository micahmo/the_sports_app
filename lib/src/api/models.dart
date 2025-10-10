class Sport {
  final String id;
  final String name;
  Sport({required this.id, required this.name});
  factory Sport.fromJson(Map<String, dynamic> j) => Sport(id: j['id'] as String, name: j['name'] as String);
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
  ApiMatch({required this.id, required this.title, required this.category, required this.date, required this.popular, required this.sources, this.poster, this.teams});
  factory ApiMatch.fromJson(Map<String, dynamic> j) => ApiMatch(
    id: j['id'] as String,
    title: j['title'] as String,
    category: j['category'] as String,
    date: (j['date'] as num).toInt(),
    poster: j['poster'] as String?,
    popular: j['popular'] as bool?,
    teams: j['teams'] != null ? MatchTeams.fromJson(j['teams']) : null,
    sources: ((j['sources'] as List<dynamic>).map((e) => MatchSourceRef.fromJson(e))).toList(),
  );
}

class StreamInfo {
  final String id;
  final int streamNo;
  final String language;
  final bool hd;
  final String embedUrl;
  final String source;
  StreamInfo({required this.id, required this.streamNo, required this.language, required this.hd, required this.embedUrl, required this.source});
  factory StreamInfo.fromJson(Map<String, dynamic> j) => StreamInfo(
    id: j['id'] as String,
    streamNo: (j['streamNo'] as num).toInt(),
    language: j['language'] as String,
    hd: j['hd'] as bool,
    embedUrl: j['embedUrl'] as String,
    source: j['source'] as String,
  );
}

enum Mode { bySport, live }
