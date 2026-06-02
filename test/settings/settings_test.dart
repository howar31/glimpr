import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/settings/settings.dart';
import 'package:glimpr/settings/settings_store.dart';

/// In-memory store so the settings logic is tested without the platform plugin.
class FakeStore implements SettingsStore {
  final Map<String, String> _m = {};
  @override
  Future<String?> getString(String key) async => _m[key];
  @override
  Future<void> setString(String key, String value) async => _m[key] = value;
  @override
  Future<void> remove(String key) async => _m.remove(key);
}

void main() {
  test('save directory round-trips and clears', () async {
    final s = Settings(FakeStore());
    expect(await s.getSaveDirectory(), isNull);
    await s.setSaveDirectory('/tmp/shots');
    expect(await s.getSaveDirectory(), '/tmp/shots');
    await s.clearSaveDirectory();
    expect(await s.getSaveDirectory(), isNull);
  });
}
