import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// What a stream actually delivered when it was last played: resolution, frame
/// rate and bitrate, as measured by the player. The site only says HD or SD,
/// and its "HD" covers anything from 720p at 30 fps to 1080p at 60.
class StreamQuality {
  const StreamQuality({required this.height, required this.fps, required this.mbps, this.adaptive = false});

  final int height;
  final int fps;
  final double mbps;

  /// The source offers more than one quality, and the player moves between
  /// them with the connection (so a stream can start lower and climb).
  final bool adaptive;

  /// "1080p60 · 8.5 Mbps", then "· adaptive" if it is.
  String get label => '${height}p$fps · ${mbps.toStringAsFixed(1)} Mbps${adaptive ? ' · adaptive' : ''}';

  static const String _key = 'streamQuality';

  // Streams belong to one match, so a measurement is only useful for a day or two.
  static const Duration _keep = Duration(days: 2);

  /// Every remembered measurement, by embed URL.
  static Future<Map<String, StreamQuality>> all() async {
    final Map<String, dynamic> raw = await _read();
    return <String, StreamQuality>{
      for (final MapEntry<String, dynamic> e in raw.entries)
        e.key: StreamQuality(
          height: e.value['h'] as int,
          fps: e.value['fps'] as int,
          mbps: (e.value['mbps'] as num).toDouble(),
          adaptive: e.value['a'] == true,
        ),
    };
  }

  /// Remember this stream's latest measurement, and forget old ones.
  Future<void> save(String embedUrl) async {
    final Map<String, dynamic> raw = await _read();
    final int now = DateTime.now().millisecondsSinceEpoch;
    raw.removeWhere((String _, dynamic v) => now - (v['at'] as int) > _keep.inMilliseconds);
    raw[embedUrl] = <String, Object>{'h': height, 'fps': fps, 'mbps': mbps, 'a': adaptive, 'at': now};
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
  bool operator ==(Object other) => other is StreamQuality && other.height == height && other.fps == fps && other.mbps == mbps && other.adaptive == adaptive;

  @override
  int get hashCode => Object.hash(height, fps, mbps, adaptive);
}
