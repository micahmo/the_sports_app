import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../app_version.dart';
import '../desktop/updater.dart';
import '../theme.dart';
import '../widgets/match_widgets.dart' show CardSegment, ScreenFrame, ScreenSpinner, ScreenTitle, SectionLabel;

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
    return ScreenFrame(
      child: Scaffold(
        appBar: AppBar(title: const ScreenTitle('Settings')),
        // Clear of a landscape phone's camera cutout, as the app bar is.
        body: SafeArea(
          top: false,
          bottom: false,
          child: _loading
              ? const ScreenSpinner()
              // Headed cards like Home's, so it reads as the same app; the
              // controls inside keep to a sensible width on a wide window.
              : ListView(
                  padding: EdgeInsets.fromLTRB(16, 4, 16, 24 + MediaQuery.paddingOf(context).bottom),
                  children: <Widget>[
                    const SectionLabel('Appearance'),
                    _card(
                      Align(
                        alignment: Alignment.centerLeft,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 480),
                          child: ValueListenableBuilder<ThemeMode>(
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
                        ),
                      ),
                    ),
                    const SectionLabel('Favorite teams and channels'),
                    _card(
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 640),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            TextField(
                              controller: _controller,
                              onChanged: _onChanged,
                              minLines: 1,
                              maxLines: 3,
                              textInputAction: TextInputAction.done,
                              decoration: const InputDecoration(hintText: 'e.g., Patriots, Celtics', border: OutlineInputBorder()),
                            ),
                            const SizedBox(height: 8),
                            Text('Separate with commas. Duplicates are ignored, spaces are trimmed.', style: Theme.of(context).textTheme.bodySmall),
                          ],
                        ),
                      ),
                    ),
                    const SectionLabel('About'),
                    // Desktop release builds update themselves (Android uses Obtainium).
                    if (!Updater.available)
                      _card(Text(appVersion.isEmpty ? 'Development build' : 'Version $appVersion'))
                    else
                      _card(
                        // The switch ends where the favorites box does (this card's
                        // padding is 4, the tile's own 12), so it stays by its label.
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 640 + 24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              // Rounded, so its hover highlight sits inside the card.
                              SwitchListTile(
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                                title: const Text('Check for updates automatically'),
                                subtitle: const Text('Version $appVersion'),
                                value: _autoUpdate,
                                onChanged: (bool on) {
                                  setState(() => _autoUpdate = on);
                                  Updater.setChecksAutomatically(on);
                                },
                              ),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                                child: OutlinedButton.icon(onPressed: () => Updater.checkNow(context), icon: const Icon(Icons.system_update_alt), label: const Text('Check now')),
                              ),
                            ],
                          ),
                        ),
                        padding: const EdgeInsets.all(4),
                      ),
                  ],
                ),
        ),
      ),
    );
  }

  // One group of settings on a card, as Home's tiles are.
  Widget _card(Widget child, {EdgeInsets padding = const EdgeInsets.all(16)}) {
    return CardSegment(
      first: true,
      last: true,
      horizontalMargin: 0,
      // Left, and loose, so a control can keep to its own width.
      child: Align(alignment: Alignment.centerLeft, child: Padding(padding: padding, child: child)),
    );
  }
}
