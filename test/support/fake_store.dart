import 'package:glimpr/settings/settings_store.dart';

/// Shared in-memory [SettingsStore] for tests. Seed initial values via the
/// constructor or poke [map] directly (e.g. to plant malformed JSON).
class FakeStore implements SettingsStore {
  FakeStore([Map<String, Object?>? seed]) {
    if (seed != null) map.addAll(seed);
  }

  final Map<String, Object?> map = {};

  @override
  Future<String?> getString(String key) async => map[key] as String?;
  @override
  Future<void> setString(String key, String value) async => map[key] = value;
  @override
  Future<bool?> getBool(String key) async => map[key] as bool?;
  @override
  Future<void> setBool(String key, bool value) async => map[key] = value;
  @override
  Future<int?> getInt(String key) async => map[key] as int?;
  @override
  Future<void> setInt(String key, int value) async => map[key] = value;
  @override
  Future<void> remove(String key) async => map.remove(key);
}
