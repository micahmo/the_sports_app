import 'package:flutter/material.dart';
import 'src/screens/sports_screen.dart';

void main() => runApp(const StreamedApp());

class StreamedApp extends StatelessWidget {
  const StreamedApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Streamed',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: const SportsScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
