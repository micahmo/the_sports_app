import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../generated/app_data.dart' show PlayerText, PlayerTuning;

/// What a stream actually delivered when it was last played: resolution, frame
/// rate and bitrate, as measured by the player. The site only says HD or SD,
/// and its "HD" covers anything from 720p at 30 fps to 1080p at 60.
class StreamQuality {
  const StreamQuality({required this.height, required this.fps, required this.mbps});

  final int height;
  final int fps;
  final double mbps;

  /// "1080p60 · 8.5 Mbps"; "1080p · 8.5 Mbps" while the frame rate is unknown.
  String get label => '$resolution · ${mbps.toStringAsFixed(1)} Mbps';

  /// "1080p60", or "1080p" while the frame rate is unknown (0).
  String get resolution => '${height}p${fps > 0 ? fps : ''}';

  static const String _key = 'streamQuality';

  // Frame rates saved before they came from the stream itself (2026-09-30)
  // could be the device's decoding speed ("1080p2", "70"): drop those.
  static int _standard(int fps) => const <int>{24, 25, 30, 48, 50, 60}.contains(fps) ? fps : 0;

  // Streams belong to one match, so a measurement is only useful for a day or two.
  static const Duration _keep = Duration(days: 2);

  /// Every remembered measurement, by embed URL.
  static Future<Map<String, StreamQuality>> all() async {
    final Map<String, dynamic> raw = await _read();
    return <String, StreamQuality>{
      for (final MapEntry<String, dynamic> e in raw.entries)
        e.key: StreamQuality(height: e.value['h'] as int, fps: _standard(e.value['fps'] as int), mbps: (e.value['mbps'] as num).toDouble()),
    };
  }

  /// Remember this stream's latest measurement, and forget old ones.
  Future<void> save(String embedUrl) async {
    final Map<String, dynamic> raw = await _read();
    final int now = DateTime.now().millisecondsSinceEpoch;
    raw.removeWhere((String _, dynamic v) => now - (v['at'] as int) > _keep.inMilliseconds);
    raw[embedUrl] = <String, Object>{'h': height, 'fps': fps, 'mbps': mbps, 'at': now};
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(raw));
  }

  static Future<Map<String, dynamic>> _read() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? s = prefs.getString(_key);
      return s == null ? <String, dynamic>{} : jsonDecode(s) as Map<String, dynamic>;
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  @override
  bool operator ==(Object other) => other is StreamQuality && other.height == height && other.fps == fps && other.mbps == mbps;

  @override
  int get hashCode => Object.hash(height, fps, mbps);
}

/// Streams that failed (never started, or reconnecting gave up), remembered
/// like their quality, through restarts, for [PlayerTuning.failedForMinutes]
/// or until they play. The lists say so where the quality goes.
abstract final class StreamFailures {
  static const String _key = 'streamFailed';
  static const Duration _keep = Duration(minutes: PlayerTuning.failedForMinutes);

  /// When each recently failed stream failed, by embed URL.
  static Future<Map<String, DateTime>> all() async {
    final DateTime now = DateTime.now();
    return <String, DateTime>{
      for (final MapEntry<String, dynamic> e in (await _read()).entries)
        if (now.difference(DateTime.fromMillisecondsSinceEpoch(e.value as int)) < _keep) e.key: DateTime.fromMillisecondsSinceEpoch(e.value as int),
    };
  }

  static Future<void> mark(String embedUrl) => _write((Map<String, dynamic> raw) => raw[embedUrl] = DateTime.now().millisecondsSinceEpoch);

  static Future<void> clear(String embedUrl) => _write((Map<String, dynamic> raw) => raw.remove(embedUrl));

  /// "Failed just now", "Failed 12 min ago", "Failed 2 hr ago".
  static String note(DateTime at) {
    final Duration ago = DateTime.now().difference(at);
    if (ago.inMinutes < 1) return PlayerText.failedJustNow;
    if (ago.inHours < 1) return PlayerText.failedMinutesAgo.replaceAll('{n}', '${ago.inMinutes}');
    return PlayerText.failedHoursAgo.replaceAll('{n}', '${ago.inHours}');
  }

  static Future<void> _write(void Function(Map<String, dynamic> raw) change) async {
    final Map<String, dynamic> raw = await _read();
    final int now = DateTime.now().millisecondsSinceEpoch;
    raw.removeWhere((String _, dynamic at) => now - (at as int) >= _keep.inMilliseconds);
    change(raw);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(raw));
  }

  static Future<Map<String, dynamic>> _read() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? s = prefs.getString(_key);
      return s == null ? <String, dynamic>{} : jsonDecode(s) as Map<String, dynamic>;
    } catch (_) {
      return <String, dynamic>{};
    }
  }
}
