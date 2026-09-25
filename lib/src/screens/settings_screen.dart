import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../app_version.dart';
import '../desktop/updater.dart';
import '../theme.dart';

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
  // Desktop: whether to look for a new version at startup.
  bool _autoUpdate = true;

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
    _autoUpdate = await Updater.checksAutomatically();
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
              padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.paddingOf(context).bottom),
              children: <Widget>[
                Text('Appearance', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                ValueListenableBuilder<ThemeMode>(
                  valueListenable: themeModeNotifier,
                  builder: (BuildContext context, ThemeMode mode, Widget? _) {
                    return SegmentedButton<ThemeMode>(
                      segments: const <ButtonSegment<ThemeMode>>[
                        ButtonSegment<ThemeMode>(value: ThemeMode.system, label: Text('System'), icon: Icon(Icons.brightness_auto)),
                        ButtonSegment<ThemeMode>(value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode)),
                        ButtonSegment<ThemeMode>(value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode)),
                      ],
                      selected: <ThemeMode>{mode},
                      onSelectionChanged: (Set<ThemeMode> s) => setThemeMode(s.first),
                    );
                  },
                ),

                const SizedBox(height: 28),
                Text('Favorite teams and channels (comma-separated)', style: Theme.of(context).textTheme.titleMedium),
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

                const SizedBox(height: 28),
                Text('About', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                // Desktop release builds update themselves (Android uses Obtainium).
                if (!Updater.available)
                  Text(appVersion.isEmpty ? 'Development build' : 'Version $appVersion')
                else ...<Widget>[
                  // Inset and rounded like the home screen's cards, so its hover
                  // highlight has room around the text.
                  SwitchListTile(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                    title: const Text('Check for updates when the app starts'),
                    subtitle: const Text('Version $appVersion'),
                    value: _autoUpdate,
                    onChanged: (bool on) {
                      setState(() => _autoUpdate = on);
                      Updater.setChecksAutomatically(on);
                    },
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(onPressed: () => Updater.checkNow(context), icon: const Icon(Icons.system_update_alt), label: const Text('Check now')),
                  ),
                ],

                // Room to grow: add more settings here later...
              ],
            ),
    );
  }
}
