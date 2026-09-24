import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'src/screens/sports_screen.dart';
import 'src/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Lets the player take the window fullscreen.
  if (Platform.isWindows) await windowManager.ensureInitialized();
  await loadThemeMode();
  runApp(const SportsApp());
}

final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

class SportsApp extends StatelessWidget {
  const SportsApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (BuildContext context, ThemeMode mode, Widget? _) {
        return MaterialApp(
          title: 'sports',
          theme: buildLightTheme(),
          darkTheme: buildDarkTheme(),
          themeMode: mode,
          home: const SportsScreen(),
          navigatorKey: _navigatorKey,
          // Esc goes back from any screen, for desktop. Screens that need Esc
          // for something else first (the player's fullscreen) handle it
          // themselves before it gets here.
          builder: (BuildContext context, Widget? child) => CallbackShortcuts(
            bindings: <ShortcutActivator, VoidCallback>{const SingleActivator(LogicalKeyboardKey.escape): () => _navigatorKey.currentState?.maybePop()},
            child: Focus(autofocus: true, child: child!),
          ),
          debugShowCheckedModeBanner: false,
        );
      },
    );
  }
}
