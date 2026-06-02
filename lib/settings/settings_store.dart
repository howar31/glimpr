import 'package:shared_preferences/shared_preferences.dart';

/// Minimal key/value backend so the Settings logic is plugin-independent and
/// testable. The real backend uses SharedPreferencesAsync (no in-memory cache,
/// so a value written by the settings engine is read fresh by the overlay
/// engine — they share NSUserDefaults within one process).
abstract class SettingsStore {
  Future<String?> getString(String key);
  Future<void> setString(String key, String value);
  Future<void> remove(String key);
}

class PrefsSettingsStore implements SettingsStore {
  final SharedPreferencesAsync _prefs = SharedPreferencesAsync();
  @override
  Future<String?> getString(String key) => _prefs.getString(key);
  @override
  Future<void> setString(String key, String value) =>
      _prefs.setString(key, value);
  @override
  Future<void> remove(String key) => _prefs.remove(key);
}
