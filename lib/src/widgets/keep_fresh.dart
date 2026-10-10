import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'match_widgets.dart' show isDesktop;

/// Tells KeepFresh screens when they're showing again (the MaterialApp's
/// navigatorObservers).
final RouteObserver<ModalRoute<void>> keepFreshRoutes = RouteObserver<ModalRoute<void>>();

/// Keeps a screen's data current without the user asking:
///
/// - when the app comes back to the foreground (onShow: back from another app,
///   the screen turning on, a restored window; not onResume, which also fires
///   when the notification shade is pulled down),
/// - on desktop, when the window gets focus again, and every minute while the
///   mouse and keyboard are idle, since a window left open never "comes back",
/// - when the user comes back to it (Back from the screen above), every time:
///   a game's sources come and go, and the site's lists change by the minute
///   (until 1.0.111, only if its data was 30 s old).
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
  ModalRoute<void>? _route;
  late final _RouteWatch _routeWatch = _RouteWatch(_refreshIfShowing);

  /// Reload this screen's data quietly.
  void refreshInBackground();

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onShow: _refreshIfShowing, onResume: isDesktop ? _refreshIfShowing : null);
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ModalRoute<void>? route = ModalRoute.of(context);
    if (route != _route) {
      keepFreshRoutes.unsubscribe(_routeWatch);
      _route = route;
      if (route != null) keepFreshRoutes.subscribe(_routeWatch, route);
    }
  }

  @override
  void dispose() {
    keepFreshRoutes.unsubscribe(_routeWatch);
    _timer?.cancel();
    _lifecycle.dispose();
    super.dispose();
  }
}

/// Back on this screen after the one above it closed.
class _RouteWatch extends RouteAware {
  _RouteWatch(this.onShowingAgain);
  final VoidCallback onShowingAgain;

  @override
  void didPopNext() => onShowingAgain();
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
