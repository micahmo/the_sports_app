import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

/// Desktop: the window comes back the way it was left, its size and position,
/// and whether it was maximized. Never fullscreen, which is the player's and
/// isn't something to start the app in.
class WindowState with WindowListener {
  WindowState._();

  static final WindowState _instance = WindowState._();

  /// Set by the player while it takes the window fullscreen (it unmaximizes
  /// first) and until it gives it back: the window's size then isn't the
  /// user's choice, so none of it is saved.
  static bool playerFullscreen = false;

  static const String _key = 'windowState';

  // The last size and position of the window when it was neither maximized nor
  // fullscreen, which is what un-maximizing returns to.
  Rect? _normal;
  Timer? _debounce;

  /// Put the window back, then keep track of it. Call before runApp: the window
  /// stays hidden until the first frame, so it appears in the right place.
  static Future<void> restore() async {
    final WindowState s = _instance;
    bool maximized = false;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_key);
      if (raw != null) {
        final Map<String, dynamic> j = jsonDecode(raw) as Map<String, dynamic>;
        final Rect r = Rect.fromLTWH((j['x'] as num).toDouble(), (j['y'] as num).toDouble(), (j['w'] as num).toDouble(), (j['h'] as num).toDouble());
        // Skip a spot on a screen that's no longer there (an unplugged monitor).
        if (r.width >= 400 && r.height >= 300 && await _onScreen(r)) {
          s._normal = r;
          await windowManager.setBounds(r);
        }
        maximized = j['maximized'] == true;
      }
    } catch (_) {}
    // Maximizing shows the window, and the runner shows it (as a normal window,
    // undoing a maximize) once the first frame is ready, so wait until it's up.
    if (maximized) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        for (int i = 0; i < 40 && !await windowManager.isVisible(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        await windowManager.maximize();
      });
    }
    windowManager.addListener(s);
    // And once more on closing: not every change sends an event (Windows moves
    // a window without one in some cases). The window waits for the save
    // (onWindowClose) instead of closing straight away.
    await windowManager.setPreventClose(true);
  }

  // Whether the window's title bar would be on one of the connected screens.
  static Future<bool> _onScreen(Rect r) async {
    final List<Display> displays = await screenRetriever.getAllDisplays();
    final Rect grip = Rect.fromLTWH(r.left + 40, r.top, 120, 30);
    for (final Display d in displays) {
      final Offset p = d.visiblePosition ?? Offset.zero;
      final Size size = d.visibleSize ?? d.size;
      if ((p & size).overlaps(grip)) return true;
    }
    return false;
  }

  // Both the continuous events and the end-of-drag ones: snapping a window
  // (Win+Arrow) or moving it from code only sends the continuous ones.
  @override
  void onWindowResize() => _changed();
  @override
  void onWindowResized() => _changed();
  @override
  void onWindowMove() => _changed();
  @override
  void onWindowMoved() => _changed();
  @override
  void onWindowMaximize() => _changed();
  @override
  void onWindowUnmaximize() => _changed();

  @override
  void onWindowClose() async {
    _debounce?.cancel();
    try {
      await _save();
    } finally {
      await windowManager.destroy();
    }
  }

  // Moves and resizes come in bursts; save once they settle.
  void _changed() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _save);
  }

  Future<void> _save() async {
    try {
      if (playerFullscreen || await windowManager.isFullScreen() || await windowManager.isMinimized()) return;
      final bool maximized = await windowManager.isMaximized();
      if (!maximized) _normal = await windowManager.getBounds();
      final Rect? r = _normal;
      if (r == null) return;
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(<String, Object>{'x': r.left, 'y': r.top, 'w': r.width, 'h': r.height, 'maximized': maximized}));
    } catch (_) {}
  }
}
