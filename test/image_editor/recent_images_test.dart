import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/image_editor/recent_images.dart';
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
  group('mergeRecent', () {
    test('prepends a new path', () {
      expect(mergeRecent(['/a', '/b'], '/c'), ['/c', '/a', '/b']);
    });

    test('moves an existing path to the front (dedup, no duplicate)', () {
      expect(mergeRecent(['/a', '/b', '/c'], '/b'), ['/b', '/a', '/c']);
    });

    test('re-adding the head is a no-op order', () {
      expect(mergeRecent(['/a', '/b'], '/a'), ['/a', '/b']);
    });

    test('caps the list length, dropping the oldest', () {
      final existing = List.generate(10, (i) => '/p$i'); // /p0 .. /p9
      final out = mergeRecent(existing, '/new', cap: 10);
      expect(out.length, 10);
      expect(out.first, '/new');
      expect(out.contains('/p9'), isFalse); // oldest dropped
      expect(out.contains('/p0'), isTrue);
    });
  });

  group('removeRecent', () {
    test('removes the path, keeping order', () {
      expect(removeRecent(['/a', '/b', '/c'], '/b'), ['/a', '/c']);
    });

    test('is a no-op when the path is absent', () {
      expect(removeRecent(['/a', '/b'], '/x'), ['/a', '/b']);
    });
  });

  group('pruneMissing', () {
    test('drops paths whose file no longer exists', () {
      final out = pruneMissing(
        ['/a', '/gone', '/b'],
        (p) => p != '/gone',
      );
      expect(out, ['/a', '/b']);
    });

    test('keeps order of survivors', () {
      final out = pruneMissing(['/x', '/y', '/z'], (_) => true);
      expect(out, ['/x', '/y', '/z']);
    });
  });

  group('RecentImagesStore', () {
    test('load returns empty list when nothing saved', () async {
      expect(await RecentImagesStore(FakeStore()).load(), isEmpty);
    });

    test('add then load round-trips, newest first', () async {
      final store = RecentImagesStore(FakeStore());
      await store.add('/a');
      await store.add('/b');
      expect(await store.load(), ['/b', '/a']);
    });

    test('add dedups and moves to front', () async {
      final store = RecentImagesStore(FakeStore());
      await store.add('/a');
      await store.add('/b');
      await store.add('/a');
      expect(await store.load(), ['/a', '/b']);
    });

    test('add caps at 30 (the landing gallery scrolls)', () async {
      final store = RecentImagesStore(FakeStore());
      for (var i = 0; i < 33; i++) {
        await store.add('/p$i');
      }
      final out = await store.load();
      expect(out.length, 30);
      expect(out.first, '/p32');
    });

    test('remove drops one entry and keeps the rest', () async {
      final store = RecentImagesStore(FakeStore());
      await store.add('/a');
      await store.add('/b');
      await store.add('/c');
      await store.remove('/b');
      expect(await store.load(), ['/c', '/a']);
    });

    test('clear empties the list', () async {
      final store = RecentImagesStore(FakeStore());
      await store.add('/a');
      await store.clear();
      expect(await store.load(), isEmpty);
    });

    test('load tolerates malformed JSON', () async {
      final fake = FakeStore();
      await fake.setString('recent_images', '{not a list');
      expect(await RecentImagesStore(fake).load(), isEmpty);
    });
  });
}
