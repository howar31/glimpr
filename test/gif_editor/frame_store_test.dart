import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/gif_editor/frame_store.dart';

Uint8List _rgba(int pixels, {int seed = 0}) =>
    Uint8List.fromList(List.generate(pixels * 4, (i) => (i + seed) & 0xFF));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late FrameStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('gifed_store');
    store = FrameStore(dir);
  });

  tearDown(() async {
    await store.dispose();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('FrameStore', () {
    test('put writes raw RGBA readable at pathFor', () async {
      final bytes = _rgba(2 * 2);
      final key = await store.put(bytes, 2, 2);
      expect(File(store.pathFor(key)).readAsBytesSync(), bytes);
    });

    test('keys are unique and stable', () async {
      final a = await store.put(_rgba(1), 1, 1);
      final b = await store.put(_rgba(1, seed: 7), 1, 1);
      expect(a, isNot(equals(b)));
      expect(store.pathFor(a), isNot(store.pathFor(b)));
      // Same key compares equal across lookups (value semantics).
      expect(a, FrameKey(a.value));
    });

    test('image decodes the stored pixels', () async {
      // 1x1 opaque red.
      final key =
          await store.put(Uint8List.fromList([255, 0, 0, 255]), 1, 1);
      final img = await store.image(key, 1, 1);
      expect(img.width, 1);
      expect(img.height, 1);
      final data = await img.toByteData();
      expect(data!.getUint8(0), 255); // R
      expect(data.getUint8(1), 0); // G
      expect(data.getUint8(3), 255); // A
    });

    test('image cache returns the identical object while warm', () async {
      final key = await store.put(_rgba(4, seed: 3), 2, 2);
      final first = await store.image(key, 2, 2);
      final second = await store.image(key, 2, 2);
      expect(identical(first, second), isTrue);
    });

    test('LRU evicts beyond the cap but frames stay readable', () async {
      final keys = <FrameKey>[];
      for (var i = 0; i < FrameStore.imageCacheCap + 6; i++) {
        keys.add(await store.put(_rgba(1, seed: i), 1, 1));
      }
      for (final k in keys) {
        await store.image(k, 1, 1);
      }
      // The earliest key fell out of the cache; a re-read still works.
      final again = await store.image(keys.first, 1, 1);
      expect(again.width, 1);
    });

    test('dispose removes the backing directory', () async {
      await store.put(_rgba(1), 1, 1);
      await store.dispose();
      expect(dir.existsSync(), isFalse);
    });

    test('thumbnail downscales the long side to the target', () async {
      // 8x4 solid teal downscales to 4x2; never upscales a small frame.
      final rgba = Uint8List(8 * 4 * 4);
      for (var i = 0; i < 8 * 4; i++) {
        rgba[i * 4] = 0;
        rgba[i * 4 + 1] = 128;
        rgba[i * 4 + 2] = 128;
        rgba[i * 4 + 3] = 255;
      }
      final key = await store.put(rgba, 8, 4);
      final thumb = await store.thumbnail(key, 8, 4, 4);
      expect(thumb.width, 4);
      expect(thumb.height, 2);
      final data = await thumb.toByteData();
      expect(data!.getUint8(1), 128); // solid survives the downscale
      final same = await store.thumbnail(key, 8, 4, 4);
      expect(identical(thumb, same), isTrue); // cached (keyed per frame)
      final key2 = await store.put(rgba, 8, 4);
      final small = await store.thumbnail(key2, 8, 4, 100);
      expect(small.width, 8); // no upscale
    });
  });
}
