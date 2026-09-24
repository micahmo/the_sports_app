import 'package:flutter/widgets.dart';

/// Calls [onResumeRefresh] when the app comes back to the foreground while this
/// screen is the one showing, so opening the app after a while shows what's on
/// now rather than games that have since finished.
///
/// Uses onShow (back from another app, or the screen turning on), not onResume,
/// which also fires when the notification shade is pulled down.
mixin RefreshOnResume<T extends StatefulWidget> on State<T> {
  late final AppLifecycleListener _lifecycle;

  /// Reload this screen's data.
  void onResumeRefresh();

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onShow: _shown);
  }

  void _shown() {
    // Screens underneath refresh when they're next shown, not now.
    if (mounted && (ModalRoute.of(context)?.isCurrent ?? true)) onResumeRefresh();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }
}
