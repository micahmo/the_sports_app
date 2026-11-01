import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'api/backend.dart';
import 'api/models.dart';
import 'player/player_log.dart';
import 'screens/streams_screen.dart' show StreamPlayerScreen;

/// A link straight into a stream, in the TV's form (see roku/app/source/main.brs):
/// `match=<id>&stream=<embed address>`, the address URL-encoded (a sport, if
/// there, isn't needed). On desktop it's a command-line argument
/// (`sports.exe "match=…&stream=…"`), on the phone an intent extra
/// (`am start … --es link "match=…&stream=…"`). For testing without clicking
/// through the lists, and for putting a stream back on after an install.
abstract final class DeepLink {
  static const MethodChannel _channel = MethodChannel('sports/link');

  /// The link the app was started with, if any.
  static Future<String?> initial(List<String> args) async {
    if (Platform.isWindows) return args.where((String a) => a.contains('match=')).firstOrNull;
    if (Platform.isAndroid) {
      try {
        return await _channel.invokeMethod<String>('initial');
      } catch (_) {}
    }
    return null;
  }

  /// Opens the link's stream over whatever's showing; the match's first stream
  /// if that one's gone. Nothing if the match isn't listed.
  static Future<void> open(NavigatorState nav, String link) async {
    final Map<String, String> q = Uri.splitQueryString(link.startsWith('?') ? link.substring(1) : link);
    final String? id = q['match'];
    if (id == null) return;
    final ApiMatch? m = (await Backend.current.fetchAllMatches()).where((ApiMatch m) => m.id == id).firstOrNull;
    if (m == null) {
      PlayerLog.add('[app] link: no match $id');
      return;
    }
    final List<StreamInfo> streams = await Backend.current.fetchMatchStreams(m);
    if (streams.isEmpty) return;
    final StreamInfo s = streams.where((StreamInfo s) => s.embedUrl == q['stream']).firstOrNull ?? streams.first;
    PlayerLog.add('[app] link: ${m.title} · ${s.name}');
    await nav.push(MaterialPageRoute<void>(allowSnapshotting: false, builder: (_) => StreamPlayerScreen(stream: s, match: m, streams: streams)));
  }
}
