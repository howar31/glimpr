import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/settings/settings.dart';
import 'package:glimpr/settings/settings_store.dart';

class FakeStore implements SettingsStore {
  final Map<String, Object> _m = {};
  @override
  Future<String?> getString(String key) async => _m[key] as String?;
  @override
  Future<void> setString(String key, String value) async => _m[key] = value;
  @override
  Future<bool?> getBool(String key) async => _m[key] as bool?;
  @override
  Future<void> setBool(String key, bool value) async => _m[key] = value;
  @override
  Future<int?> getInt(String key) async => _m[key] as int?;
  @override
  Future<void> setInt(String key, int value) async => _m[key] = value;
  @override
  Future<void> remove(String key) async => _m.remove(key);
}

void main() {
  test('capture layer cap defaults to 1 and clamps to 1-5', () async {
    final s = Settings(FakeStore());
    expect(await s.getCaptureLayerCap(), 1);
    await s.setCaptureLayerCap(3);
    expect(await s.getCaptureLayerCap(), 3);
    await s.setCaptureLayerCap(99);
    expect(await s.getCaptureLayerCap(), 5);
    await s.setCaptureLayerCap(0);
    expect(await s.getCaptureLayerCap(), 1);
  });
}
