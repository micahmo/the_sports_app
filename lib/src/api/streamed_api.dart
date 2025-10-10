import 'dart:convert';
import 'package:http/http.dart' as http;
import 'models.dart';

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

  Future<List<StreamInfo>> fetchStreams(String source, String id) async {
    final http.Response r = await _client.get(Uri.parse('$base/api/stream/$source/$id'));
    _ensureOk(r);
    final List<dynamic> arr = jsonDecode(r.body) as List<dynamic>;
    return arr.map((e) => StreamInfo.fromJson(e as Map<String, dynamic>)).toList();
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
