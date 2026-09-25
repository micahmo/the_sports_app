import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../app_version.dart';
import 'window_state.dart';

/// Desktop: finds a newer release on GitHub, offers it, and installs it over
/// this copy of the app, then starts it again. (Android updates through
/// Obtainium; the Roku can only point at a new release, since installing needs
/// its developer-mode password.)
class Updater {
  Updater._();

  /// Local builds have no version (see appVersion), and never offer updates.
  static const String version = appVersion;

  static const String _releasesApi = 'https://api.github.com/repos/micahmo/the_sports_app/releases/latest';
  static const String releasesPage = 'https://github.com/micahmo/the_sports_app/releases/latest';
  static const String _autoKey = 'updateCheckAutomatically';

  static bool get available => Platform.isWindows && version.isNotEmpty;

  static Future<bool> checksAutomatically() async => (await SharedPreferences.getInstance()).getBool(_autoKey) ?? true;

  static Future<void> setChecksAutomatically(bool on) async => (await SharedPreferences.getInstance()).setBool(_autoKey, on);

  /// At every startup, if it's switched on in Settings.
  static Future<void> checkAtStartup(BuildContext Function() context) async {
    if (!available || !await checksAutomatically()) return;
    final _Release? release = await _latest();
    if (release == null) return;
    final BuildContext c = context();
    if (release.isNewer && c.mounted) await _offer(c, release);
  }

  /// From Settings: always checks, and says so when there's nothing new.
  static Future<void> checkNow(BuildContext context) async {
    final _Release? release = await _latest();
    if (!context.mounted) return;
    if (release == null) {
      _say(context, "Couldn't check for updates. Try again later.");
    } else if (!release.isNewer) {
      _say(context, 'You have the latest version ($version).');
    } else {
      await _offer(context, release);
    }
  }

  static Future<_Release?> _latest() async {
    try {
      final http.Response r = await http.get(Uri.parse(_releasesApi), headers: <String, String>{'Accept': 'application/vnd.github+json'}).timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return null;
      final Map<String, dynamic> j = jsonDecode(r.body) as Map<String, dynamic>;
      final String tag = (j['tag_name'] as String? ?? '').replaceFirst('v', '');
      for (final dynamic a in j['assets'] as List<dynamic>? ?? <dynamic>[]) {
        final Map<String, dynamic> asset = a as Map<String, dynamic>;
        final String name = asset['name'] as String? ?? '';
        if (name.startsWith('sports-windows-x64-') && name.endsWith('.zip')) {
          return _Release(tag, j['body'] as String? ?? '', asset['browser_download_url'] as String, (asset['size'] as num).toInt());
        }
      }
    } catch (_) {}
    return null;
  }

  static Future<void> _offer(BuildContext context, _Release release) async {
    final bool? update = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => AlertDialog(
        title: Text('Version ${release.version} is available'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text('You have $version. Update now? The app restarts on the new version.'),
                if (release.notes.trim().isNotEmpty) ...<Widget>[
                  const SizedBox(height: 16),
                  Text("What's new", style: Theme.of(c).textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(release.notes.trim(), style: Theme.of(c).textTheme.bodySmall),
                ],
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Update')),
        ],
      ),
    );
    if (update == true && context.mounted) await _install(context, release);
  }

  static Future<void> _install(BuildContext context, _Release release) async {
    final Directory appDir = File(Platform.resolvedExecutable).parent;
    // Unzipped somewhere Windows won't let us write (Program Files): the user
    // has to replace it themselves.
    if (!_writable(appDir)) {
      await _manual(context, "This copy of the app is in a folder it can't write to, so it can't update itself.");
      return;
    }
    final ValueNotifier<double?> progress = ValueNotifier<double?>(null);
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext c) => AlertDialog(
          title: Text('Downloading ${release.version}'),
          content: ValueListenableBuilder<double?>(valueListenable: progress, builder: (_, double? v, _) => LinearProgressIndicator(value: v)),
        ),
      ),
    );
    final File zip = File('${Directory.systemTemp.path}\\sports-update-${release.version}.zip');
    try {
      await _download(release, zip, progress);
    } catch (_) {
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        await _manual(context, "The download didn't finish.");
      }
      return;
    }
    await _replaceAndRestart(zip, appDir);
  }

  static bool _writable(Directory dir) {
    try {
      final File probe = File('${dir.path}\\.update-check');
      probe.writeAsStringSync('');
      probe.deleteSync();
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _download(_Release release, File zip, ValueNotifier<double?> progress) async {
    final http.StreamedResponse r = await http.Client().send(http.Request('GET', Uri.parse(release.url)));
    if (r.statusCode != 200) throw HttpException('HTTP ${r.statusCode}');
    final IOSink out = zip.openWrite();
    int got = 0;
    await for (final List<int> chunk in r.stream) {
      out.add(chunk);
      got += chunk.length;
      progress.value = got / release.size;
    }
    await out.close();
    if (await zip.length() != release.size) throw const FileSystemException('Incomplete download');
  }

  // The running app can't overwrite itself (Windows locks its exe and DLLs), so
  // a small script waits for it to exit, unzips the new version over this
  // folder and starts it again, and starts this version again if anything goes
  // wrong.
  static Future<void> _replaceAndRestart(File zip, Directory appDir) async {
    String ps(String s) => "'${s.replaceAll("'", "''")}'";
    final String staging = '${Directory.systemTemp.path}\\sports-update';
    final File script = File('${Directory.systemTemp.path}\\sports-update.ps1');
    await script.writeAsString('''
\$ErrorActionPreference = 'Stop'
Wait-Process -Id $pid -ErrorAction SilentlyContinue
try {
    if (Test-Path ${ps(staging)}) { Remove-Item ${ps(staging)} -Recurse -Force }
    Expand-Archive -Path ${ps(zip.path)} -DestinationPath ${ps(staging)} -Force
    Copy-Item -Path (Join-Path ${ps(staging)} '*') -Destination ${ps(appDir.path)} -Recurse -Force
} finally {
    Remove-Item ${ps(staging)} -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item ${ps(zip.path)} -Force -ErrorAction SilentlyContinue
    Start-Process -FilePath (Join-Path ${ps(appDir.path)} 'sports.exe')
    Remove-Item \$PSCommandPath -Force -ErrorAction SilentlyContinue
}
''');
    // Through `start`, which gives PowerShell a console of its own: started
    // detached without one, it exits straight away without running the script.
    await Process.start('cmd.exe', <String>['/c', 'start', '/min', 'powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', script.path], mode: ProcessStartMode.detached);
    await WindowState.saveNow();
    exit(0);
  }

  static Future<void> _manual(BuildContext context, String why) async {
    final bool? open = await showDialog<bool>(
      context: context,
      builder: (BuildContext c) => AlertDialog(
        title: const Text("Couldn't update"),
        content: Text('$why You can download the new version and replace this one yourself.'),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Close')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Open the download page')),
        ],
      ),
    );
    if (open == true) await Process.start('explorer.exe', <String>[releasesPage]);
  }

  static void _say(BuildContext context, String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

class _Release {
  _Release(this.version, this.notes, this.url, this.size);
  final String version;
  final String notes;
  final String url;
  final int size;

  /// Newer than this build, comparing 1.0.80 as numbers.
  bool get isNewer {
    final List<int> a = version.split('.').map((String s) => int.tryParse(s) ?? 0).toList();
    final List<int> b = Updater.version.split('.').map((String s) => int.tryParse(s) ?? 0).toList();
    for (int i = 0; i < a.length && i < b.length; i++) {
      if (a[i] != b[i]) return a[i] > b[i];
    }
    return a.length > b.length;
  }
}
