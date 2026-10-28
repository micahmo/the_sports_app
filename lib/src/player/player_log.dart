import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// The player's log in a file, to read after the fact: the phone's system log
/// rolls over within the hour (a replay at 7:33 PM on 2026-10-25 was gone by
/// 8:45), and desktop has no log at all. About a megabyte, then the one before
/// as player.1.log. Android: /sdcard/Android/data/com.micahmo.sports/files/
/// (`adb shell cat`, release builds too); Windows: the app's support folder.
abstract final class PlayerLog {
  static const int _maxBytes = 1000000;
  static File? _file;
  static bool _opening = false;
  static final List<String> _waiting = <String>[];
  static int _sinceCheck = 0;

  static void add(String line) {
    final String stamped = '${DateTime.now().toIso8601String()} $line\n';
    final File? f = _file;
    if (f != null) {
      _write(f, stamped);
      return;
    }
    if (_waiting.length < 500) _waiting.add(stamped);
    if (!_opening) {
      _opening = true;
      _open();
    }
  }

  static Future<void> _open() async {
    try {
      final Directory? dir = Platform.isAndroid ? await getExternalStorageDirectory() : await getApplicationSupportDirectory();
      if (dir == null) return;
      final File f = File('${dir.path}${Platform.pathSeparator}player.log');
      _file = f;
      _write(f, _waiting.join());
      _waiting.clear();
    } catch (_) {
      // No log, then; playing doesn't depend on it.
    }
  }

  static void _write(File f, String text) {
    try {
      f.writeAsStringSync(text, mode: FileMode.append);
      if (++_sinceCheck < 200) return;
      _sinceCheck = 0;
      if (f.lengthSync() < _maxBytes) return;
      final File old = File(f.path.replaceFirst(RegExp(r'\.log$'), '.1.log'));
      if (old.existsSync()) old.deleteSync();
      f.renameSync(old.path);
    } catch (_) {}
  }
}
