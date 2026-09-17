import 'package:flutter/material.dart';

/// App-wide preferences. Kept in memory for now — nothing here is worth a
/// database table, and the next natural home is shared_preferences.
class SettingsViewModel extends ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.dark;

  ThemeMode get themeMode => _themeMode;
  bool get isDark => _themeMode == ThemeMode.dark;

  void setThemeMode(ThemeMode mode) {
    if (_themeMode == mode) return;
    _themeMode = mode;
    notifyListeners();
  }

  void toggleTheme() =>
      setThemeMode(_themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark);
}
