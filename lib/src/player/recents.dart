import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../api/models.dart';
import '../generated/app_data.dart' show PlayerTuning;

/// A game played recently and the stream it was watched on, for the player's
/// streams row (RECENT). One per game: playing another of its streams replaces
/// it.
class RecentGame {
  RecentGame({required this.match, required this.stream, required this.at});

  final ApiMatch match;
  final StreamInfo stream;

  /// When it last started playing (ms since epoch).
  final int at;

  Map<String, dynamic> toJson() => <String, dynamic>{'match': match.toJson(), 'stream': stream.toJson(), 'at': at};

  static RecentGame fromJson(Map<String, dynamic> j) => RecentGame(
    match: ApiMatch.fromJson(j['match'] as Map<String, dynamic>),
    stream: StreamInfo.fromJson(j['stream'] as Map<String, dynamic>),
    at: (j['at'] as num).toInt(),
  );
}

class Recents {
  static const String _key = 'recentGames';

  // Plenty for a row that shows a few; finished games drop out when shown.
  static const int _keep = PlayerTuning.recentsKept;

  /// Newest first.
  static Future<List<RecentGame>> all() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? s = prefs.getString(_key);
      if (s == null) return <RecentGame>[];
      return <RecentGame>[for (final dynamic e in jsonDecode(s) as List<dynamic>) RecentGame.fromJson(e as Map<String, dynamic>)];
    } catch (_) {
      return <RecentGame>[];
    }
  }

  /// Remember that [stream] of [match] is playing now.
  static Future<void> played(ApiMatch match, StreamInfo stream) async {
    final List<RecentGame> list = await all();
    list.removeWhere((RecentGame r) => r.match.id == match.id);
    list.insert(0, RecentGame(match: match, stream: stream, at: DateTime.now().millisecondsSinceEpoch));
    if (list.length > _keep) list.removeRange(_keep, list.length);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(<Map<String, dynamic>>[for (final RecentGame r in list) r.toJson()]));
  }
}
