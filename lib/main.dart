import 'package:flutter/material.dart';
import 'src/screens/sports_screen.dart';
import 'src/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadThemeMode();
  runApp(const StreamedApp());
}

class StreamedApp extends StatelessWidget {
  const StreamedApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (BuildContext context, ThemeMode mode, Widget? _) {
        return MaterialApp(
          title: 'Streamed',
          theme: buildLightTheme(),
          darkTheme: buildDarkTheme(),
          themeMode: mode,
          home: const SportsScreen(),
          debugShowCheckedModeBanner: false,
        );
      },
    );
  }
}
