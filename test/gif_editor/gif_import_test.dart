import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/gif_editor/frame_store.dart';
import 'package:glimpr/gif_editor/gif_import.dart';

import '../support/gif_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late FrameStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('gifed_import');
    store = FrameStore(dir);
  });

  tearDown(() async {
    await store.dispose();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('importGif', () {
    test('decodes frames, delays and loop count', () async {
      final doc = await importGif(twoFrameGifFixture(), store);
      expect(doc.frameCount, 2);
      expect(doc.loopCount, 0); // NETSCAPE 0 = forever
      expect(doc.frames[0].delayMs, 200);
      expect(doc.frames[1].delayMs, 400);
      expect(doc.frames[0].width, 2);
      expect(doc.frames[0].height, 2);
    });

    test('frame pixels land in the store (frame 1 top-left is red)', () async {
      final doc = await importGif(twoFrameGifFixture(), store);
      final rgba = File(store.pathFor(doc.frames[0].key)).readAsBytesSync();
      expect(rgba.length, 2 * 2 * 4);
      expect(rgba[0], 255); // R
      expect(rgba[1], 0); // G
      expect(rgba[2], 0); // B
      expect(rgba[3], 255); // A
      // Frame 2 is solid blue.
      final rgba2 = File(store.pathFor(doc.frames[1].key)).readAsBytesSync();
      expect(rgba2[0], 0);
      expect(rgba2[2], 255);
    });

    test('reports progress per decoded frame', () async {
      final seen = <int>[];
      await importGif(twoFrameGifFixture(), store,
          onProgress: (done, total) => seen.add(done));
      expect(seen, [1, 2]);
    });

    test('zero-delay frames normalize to 100ms', () async {
      final bytes = twoFrameGifFixture();
      // Zero out frame 1's delay (GCE delay bytes follow 21 F9 04 00).
      final gceIndex = _indexOfGce(bytes, 0);
      bytes[gceIndex + 4] = 0;
      bytes[gceIndex + 5] = 0;
      final doc = await importGif(bytes, store);
      expect(doc.frames[0].delayMs, 100);
      expect(doc.frames[1].delayMs, 400);
    });
  });
}

/// Offset of the Nth Graphic Control Extension introducer (0x21 0xF9).
int _indexOfGce(List<int> bytes, int n) {
  var seen = 0;
  for (var i = 0; i < bytes.length - 1; i++) {
    if (bytes[i] == 0x21 && bytes[i + 1] == 0xF9) {
      if (seen == n) return i;
      seen++;
    }
  }
  throw StateError('GCE $n not found');
}
