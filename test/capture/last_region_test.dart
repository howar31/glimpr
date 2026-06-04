import 'dart:ui' show Rect;
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/capture/last_region.dart';
import 'package:glimpr/settings/settings_store.dart';

/// In-memory SettingsStore for tests.
class FakeStore implements SettingsStore {
  final Map<String, Object> _m = {};
  @override
  Future<String?> getString(String k) async => _m[k] as String?;
  @override
  Future<void> setString(String k, String v) async => _m[k] = v;
  @override
  Future<bool?> getBool(String k) async => _m[k] as bool?;
  @override
  Future<void> setBool(String k, bool v) async => _m[k] = v;
  @override
  Future<int?> getInt(String k) async => _m[k] as int?;
  @override
  Future<void> setInt(String k, int v) async => _m[k] = v;
  @override
  Future<void> remove(String k) async => _m.remove(k);
}

void main() {
  test('save then load round-trips the displayId + rect', () async {
    final store = LastRegionStore(FakeStore());
    await store.save(
        const LastRegion(displayId: 7, rect: Rect.fromLTWH(10, 20, 300, 400)));
    final r = await store.load();
    expect(r, isNotNull);
    expect(r!.displayId, 7);
    expect(r.rect, const Rect.fromLTWH(10, 20, 300, 400));
  });

  test('load returns null when nothing was saved', () async {
    expect(await LastRegionStore(FakeStore()).load(), isNull);
  });

  test('load returns null on malformed JSON', () async {
    final fake = FakeStore();
    await fake.setString('last_region', 'not json');
    expect(await LastRegionStore(fake).load(), isNull);
  });

  group('resolveRecordedRect', () {
    test('prefers the explicit selection (a manual crop)', () {
      final r = resolveRecordedRect(
          const Rect.fromLTWH(5, 6, 100, 80), null, 1920, 1080);
      expect(r, const Rect.fromLTWH(5, 6, 100, 80));
    });
    test('falls back to the snap window rect when there is no selection', () {
      final r = resolveRecordedRect(
          null, const Rect.fromLTWH(40, 50, 200, 150), 1920, 1080);
      expect(r, const Rect.fromLTWH(40, 50, 200, 150));
    });
    test('falls back to the whole display when neither is present', () {
      final r = resolveRecordedRect(null, null, 1920, 1080);
      expect(r, const Rect.fromLTWH(0, 0, 1920, 1080));
    });
  });
}
