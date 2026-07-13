import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/gif_editor/encode/gif_writer.dart';
import 'package:glimpr/gif_editor/encode/palette.dart';
import 'package:glimpr/gif_editor/export_service.dart';
import 'package:glimpr/gif_editor/frame_store.dart';
import 'package:glimpr/gif_editor/gif_import.dart';

Uint8List _solid(int w, int h, List<int> rgba) {
  final out = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    out.setRange(i * 4, i * 4 + 4, rgba);
  }
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Palette.fixed216', () {
    test('primary colors map exactly', () {
      final p = Palette.fixed216();
      for (final c in [
        [255, 0, 0],
        [0, 255, 0],
        [0, 0, 255],
        [255, 255, 255],
        [0, 0, 0],
      ]) {
        final idx = p.indexOf(c[0], c[1], c[2]);
        expect(idx, lessThan(Palette.transparentIndex));
        expect([p.rgb[idx * 3], p.rgb[idx * 3 + 1], p.rgb[idx * 3 + 2]], c);
      }
    });
  });

  group('encodeGifFrames', () {
    test('round-trips frames, delays and loop through the real decoder',
        () async {
      // Frame 1: 2x2 red/green/blue/white; frame 2: solid blue.
      final f1 = Uint8List.fromList([
        255, 0, 0, 255, //
        0, 255, 0, 255, //
        0, 0, 255, 255, //
        255, 255, 255, 255, //
      ]);
      final f2 = _solid(2, 2, [0, 0, 255, 255]);
      final gif = encodeGifFrames(
        frames: [FrameSpec(f1, 200), FrameSpec(f2, 400)],
        width: 2,
        height: 2,
        loopCount: 0,
      );

      final dir = await Directory.systemTemp.createTemp('gifed_writer');
      final store = FrameStore(dir);
      try {
        final doc = await importGif(gif, store);
        expect(doc.frameCount, 2);
        expect(doc.loopCount, 0);
        expect(doc.frames[0].delayMs, 200);
        expect(doc.frames[1].delayMs, 400);
        final back =
            File(store.pathFor(doc.frames[0].key)).readAsBytesSync();
        expect(back, f1); // fixed216 palette is exact for primaries
        final back2 =
            File(store.pathFor(doc.frames[1].key)).readAsBytesSync();
        expect(back2, f2);
      } finally {
        await store.dispose();
      }
    });

    test('solid frame stays tiny (LZW works)', () async {
      final gif = encodeGifFrames(
        frames: [FrameSpec(_solid(4, 4, [0, 255, 0, 255]), 100)],
        width: 4,
        height: 4,
        loopCount: 0,
      );
      expect(gif.length, lessThan(200 + 768)); // header + GCT dominate
      final dir = await Directory.systemTemp.createTemp('gifed_writer');
      final store = FrameStore(dir);
      try {
        final doc = await importGif(gif, store);
        expect(doc.frames.single.width, 4);
      } finally {
        await store.dispose();
      }
    });

    test('fully transparent pixels round-trip as transparent', () async {
      final f = _solid(2, 1, [255, 0, 0, 255]);
      f[7] = 0; // second pixel alpha = 0
      final gif = encodeGifFrames(
        frames: [FrameSpec(f, 100)],
        width: 2,
        height: 1,
        loopCount: 0,
      );
      final dir = await Directory.systemTemp.createTemp('gifed_writer');
      final store = FrameStore(dir);
      try {
        final doc = await importGif(gif, store);
        final back = File(store.pathFor(doc.frames.single.key))
            .readAsBytesSync();
        expect(back[3], 255); // first pixel opaque red
        expect(back[0], 255);
        expect(back[7], 0); // second pixel transparent
      } finally {
        await store.dispose();
      }
    });

    test('a 300-frame gradient encodes without hitting the code cap',
        () async {
      // Exercises dictionary growth + the 4096 reset path with varied data.
      final frames = <FrameSpec>[];
      for (var i = 0; i < 300; i++) {
        final f = Uint8List(16 * 16 * 4);
        for (var p = 0; p < 16 * 16; p++) {
          f[p * 4] = (p * 3 + i * 5) & 0xFF;
          f[p * 4 + 1] = (p * 7 + i * 11) & 0xFF;
          f[p * 4 + 2] = (p * 13 + i * 2) & 0xFF;
          f[p * 4 + 3] = 255;
        }
        frames.add(FrameSpec(f, 50));
      }
      final gif = encodeGifFrames(
          frames: frames, width: 16, height: 16, loopCount: 3);
      final dir = await Directory.systemTemp.createTemp('gifed_writer');
      final store = FrameStore(dir);
      try {
        final doc = await importGif(gif, store);
        expect(doc.frameCount, 300);
        expect(doc.loopCount, 3);
        expect(doc.frames.first.delayMs, 50);
      } finally {
        await store.dispose();
      }
    });
  });

  group('exportGif', () {
    test('writes a decodable file with progress', () async {
      final dir = await Directory.systemTemp.createTemp('gifed_export');
      final store = FrameStore(dir);
      try {
        final doc = await importGif(
            encodeGifFrames(
              frames: [
                FrameSpec(_solid(2, 2, [255, 0, 0, 255]), 200),
                FrameSpec(_solid(2, 2, [0, 0, 255, 255]), 300),
              ],
              width: 2,
              height: 2,
              loopCount: 0,
            ),
            store);
        final out = '${dir.path}/out.gif';
        final seen = <int>[];
        await exportGif(
          doc: doc,
          store: store,
          outPath: out,
          onProgress: (done, total) => seen.add(done),
        );
        expect(seen.last, 2);
        final reread = await importGif(
            Uint8List.fromList(File(out).readAsBytesSync()), store);
        expect(reread.frameCount, 2);
        expect(reread.frames[0].delayMs, 200);
        expect(reread.frames[1].delayMs, 300);
      } finally {
        await store.dispose();
      }
    });
  });
}
