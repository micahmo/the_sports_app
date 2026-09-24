import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Current theme preference. The app listens to this so Settings can change the
/// theme without restarting.
final ValueNotifier<ThemeMode> themeModeNotifier = ValueNotifier<ThemeMode>(ThemeMode.system);

const String _themeModePrefsKey = 'themeMode';

Future<void> loadThemeMode() async {
  try {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    themeModeNotifier.value = _decode(prefs.getString(_themeModePrefsKey));
  } catch (_) {
    // Stick with the system default if prefs are unavailable.
  }
}

Future<void> setThemeMode(ThemeMode mode) async {
  themeModeNotifier.value = mode;
  try {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeModePrefsKey, _encode(mode));
  } catch (_) {}
}

String _encode(ThemeMode m) => switch (m) {
  ThemeMode.light => 'light',
  ThemeMode.dark => 'dark',
  ThemeMode.system => 'system',
};

ThemeMode _decode(String? s) => switch (s) {
  'light' => ThemeMode.light,
  'dark' => ThemeMode.dark,
  _ => ThemeMode.system,
};

// Deliberately a dark grey rather than black: easier on the eyes in a lit room
// and it keeps the elevation steps visible. Text is kept well clear of the
// minimum contrast (body text lands around 12:1 on the background, secondary
// text around 9:1, against a WCAG AA floor of 4.5:1).
const Color _darkSurface = Color(0xFF22252A);
const Color _darkContainer = Color(0xFF2B2F36);
const Color _darkContainerHigh = Color(0xFF32363E);
const Color _darkOnSurface = Color(0xFFE7E9EE);
const Color _darkOnSurfaceVariant = Color(0xFFC2C7D0);
const Color _darkPrimary = Color(0xFFAEB8FF);

/// Headings, labels and numbers use this condensed face; body text stays Roboto.
const String kCondensedFont = 'BarlowSemiCondensed';

TextStyle condensed(double size, FontWeight weight, {Color? color, double letterSpacing = 0}) =>
    TextStyle(fontFamily: kCondensedFont, fontSize: size, fontWeight: weight, color: color, letterSpacing: letterSpacing, height: 1.15);

/// Barlow's ascent is five times its descent, so its capitals and figures sit
/// below the middle of their line box. A dot or icon centred beside them looks
/// high; move it down by this much to line up with the letters.
double capsCenterShift(double fontSize) => fontSize * 0.065;

/// Team badges sit on a light disc: plenty of logos are dark (Yankees, White
/// Sox…) and disappear against the dark theme otherwise.
Color badgeDiscColor(BuildContext c) => adaptiveColor(c, light: const Color(0xFFFFFFFF), dark: const Color(0xFFE6E8EE));

/// Picks between two shades of the same hue so accent colours stay legible on
/// both backgrounds — the light theme needs darker shades, the dark theme
/// lighter ones.
Color adaptiveColor(BuildContext context, {required Color light, required Color dark}) =>
    Theme.of(context).brightness == Brightness.dark ? dark : light;

/// Accents for the shortcut rows at the top of the sports list.
Color liveColor(BuildContext c) => adaptiveColor(c, light: const Color(0xFFD32F2F), dark: const Color(0xFFFF6B6B));
Color popularColor(BuildContext c) => adaptiveColor(c, light: const Color(0xFFC0410A), dark: const Color(0xFFFFA24D));
Color favoriteColor(BuildContext c) => adaptiveColor(c, light: const Color(0xFFC2185B), dark: const Color(0xFFFF7BAC));

/// The two glyphs differ by a single letter and were hard to tell apart when
/// both were grey. Green for HD and amber for SD so the colour matches the
/// quality rather than fighting it.
Color hdColor(BuildContext c) => adaptiveColor(c, light: const Color(0xFF277A31), dark: const Color(0xFF7BD88F));
Color sdColor(BuildContext c) => adaptiveColor(c, light: const Color(0xFFA15C00), dark: const Color(0xFFE8B76B));

ThemeData buildLightTheme() => ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo);

ThemeData buildDarkTheme() {
  const ColorScheme scheme = ColorScheme.dark(
    primary: _darkPrimary,
    onPrimary: Color(0xFF1A1F4D),
    primaryContainer: Color(0xFF3B4392),
    onPrimaryContainer: Color(0xFFDDE1FF),
    secondary: Color(0xFFC3C5DD),
    onSecondary: Color(0xFF2C2F42),
    surface: _darkSurface,
    onSurface: _darkOnSurface,
    surfaceContainerLowest: Color(0xFF1C1F23),
    surfaceContainerLow: Color(0xFF262A30),
    surfaceContainer: _darkContainer,
    surfaceContainerHigh: _darkContainerHigh,
    surfaceContainerHighest: Color(0xFF3A3F48),
    onSurfaceVariant: _darkOnSurfaceVariant,
    outline: Color(0xFF8C919B),
    outlineVariant: Color(0xFF44484F),
    error: Color(0xFFFFB4AB),
    onError: Color(0xFF690005),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    // Several places read hintColor for secondary text (e.g. viewer counts);
    // the default is too dim against this background.
    hintColor: _darkOnSurfaceVariant,
    dividerColor: scheme.outlineVariant,
    appBarTheme: AppBarTheme(backgroundColor: scheme.surface, foregroundColor: scheme.onSurface, elevation: 0),
  );
}
