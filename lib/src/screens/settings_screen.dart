import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const String _prefsKey = 'favoriteTeams';

  final TextEditingController _controller = TextEditingController();
  bool _loading = true;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final List<String> saved = prefs.getStringList(_prefsKey) ?? <String>[];
    // Join into a comma-separated string for the textbox
    _controller.text = saved.join(', ');
    setState(() => _loading = false);
  }

  // Debounced auto-save on typing
  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      _saveFromText(value);
    });
  }

  Future<void> _saveFromText(String text) async {
    // Parse: split by comma, trim, drop empties, de-duplicate (preserve order)
    final List<String> raw = text.split(',');
    final List<String> cleaned = <String>[];
    final Set<String> seen = <String>{};
    for (final String s in raw) {
      final String t = s.trim();
      if (t.isEmpty) continue;
      if (seen.add(t.toLowerCase())) {
        cleaned.add(t); // keep original casing, unique by lowercase
      }
    }

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsKey, cleaned);
    // Optional quick feedback without being noisy:
    // ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                Text('Favorite teams (comma-separated)', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                TextField(
                  controller: _controller,
                  onChanged: _onChanged,
                  minLines: 1,
                  maxLines: 3,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(hintText: 'e.g., Patriots, Celtics', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 8),
                Text('Tip: Separate with commas. Duplicates are ignored, spaces are trimmed.', style: Theme.of(context).textTheme.bodySmall),

                // Room to grow: add more settings here later...
              ],
            ),
    );
  }
}
