import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'match_widgets.dart' show isDesktop;

/// Keeps a screen's data current without the user asking:
///
/// - when the app comes back to the foreground (onShow: back from another app,
///   the screen turning on, a restored window; not onResume, which also fires
///   when the notification shade is pulled down), and
/// - on desktop, every minute while the mouse and keyboard are idle, since a
///   window left open never "comes back".
///
/// Only the screen that's showing refreshes; screens underneath (including
/// everything under the player) catch up when they're next shown.
///
/// [refreshInBackground] should be quiet: keep showing the current data until
/// the new data arrives, and keep it if the refresh fails.
mixin KeepFresh<T extends StatefulWidget> on State<T> {
  static const Duration _interval = Duration(minutes: 1);

  /// Input this recent means someone is using the window; wait for the next tick.
  static const Duration _idleBefore = Duration(seconds: 10);

  late final AppLifecycleListener _lifecycle;
  Timer? _timer;

  /// Reload this screen's data quietly.
  void refreshInBackground();

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onShow: _refreshIfShowing);
    if (isDesktop) {
      _UserActivity.ensureListening();
      _timer = Timer.periodic(_interval, (_) => _tick());
    }
  }

  void _tick() {
    if (_UserActivity.idleFor < _idleBefore) return;
    final AppLifecycleState? app = WidgetsBinding.instance.lifecycleState;
    // Minimized: onShow refreshes when it's restored.
    if (app == AppLifecycleState.hidden || app == AppLifecycleState.paused) return;
    _refreshIfShowing();
  }

  void _refreshIfShowing() {
    if (mounted && (ModalRoute.of(context)?.isCurrent ?? true)) refreshInBackground();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _lifecycle.dispose();
    super.dispose();
  }
}

/// When the user last moved the mouse, scrolled, clicked or pressed a key.
class _UserActivity {
  static DateTime _last = DateTime.now();
  static bool _listening = false;

  static Duration get idleFor => DateTime.now().difference(_last);

  static void ensureListening() {
    if (_listening) return;
    _listening = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute((PointerEvent _) => _last = DateTime.now());
    HardwareKeyboard.instance.addHandler((KeyEvent _) {
      _last = DateTime.now();
      return false; // only watching; let the key through
    });
  }
}
