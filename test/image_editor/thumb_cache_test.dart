import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:glimpr/image_editor/thumb_cache.dart';

/// Encode a [w]x[h] solid-color image to PNG bytes (codec-only, no raster).
Future<Uint8List> _pngBytes(int w, int h) async {
  final pixels = Uint8List(w * h * 4);
  for (var i = 0; i < pixels.length; i += 4) {
    pixels[i] = 0xE0; // R
    pixels[i + 3] = 0xFF; // A
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
      pixels, w, h, ui.PixelFormat.rgba8888, completer.complete);
  final img = await completer.future;
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return data!.buffer.asUint8List();
}

/// Encode a [w]x[h] PNG whose pixel colors come from [colorAt](x, y) — RGBA.
Future<Uint8List> _paintedPngBytes(
    int w, int h, List<int> Function(int x, int y) colorAt) async {
  final pixels = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final c = colorAt(x, y);
      final i = (y * w + x) * 4;
      pixels[i] = c[0];
      pixels[i + 1] = c[1];
      pixels[i + 2] = c[2];
      pixels[i + 3] = 255;
    }
  }
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
      pixels, w, h, ui.PixelFormat.rgba8888, completer.complete);
  final img = await completer.future;
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return data!.buffer.asUint8List();
}

/// Decode [file] and return (width, height, rawRgba bytes).
Future<(int, int, Uint8List)> _decode(File file) async {
  final codec = await ui.instantiateImageCodec(await file.readAsBytes());
  final frame = await codec.getNextFrame();
  codec.dispose();
  final img = frame.image;
  final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  final out = (img.width, img.height, data!.buffer.asUint8List());
  img.dispose();
  return out;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('thumbKey / fnv1a32', () {
    test('stable and collision-distinct for different paths', () {
      expect(fnv1a32('/a/b.png'), fnv1a32('/a/b.png'));
      expect(fnv1a32('/a/b.png'), isNot(fnv1a32('/a/c.png')));
      expect(fnv1a32('/a/b.png'), greaterThanOrEqualTo(0));
    });

    test('key format groups generations by path-hash prefix', () {
      final k1 = thumbKey('/a/b.png', 111, 5);
      final k2 = thumbKey('/a/b.png', 222, 9);
      expect(k1, endsWith('.png'));
      expect(k1.split('-').first, k2.split('-').first);
      expect(k1, isNot(k2));
      // Format version: cover-cropped sidecars must not be served from keys
      // of the old height-bound generation.
      expect(k1, contains('-v2-'));
    });
  });

  group('ThumbCache', () {
    late Directory tmp;
    late ThumbCache cache;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('thumb_cache_test');
      cache = ThumbCache(dir: Directory(p.join(tmp.path, 'thumbs')));
    });

    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    test('generates a downscaled sidecar and serves it on the next lookup',
        () async {
      final src = File(p.join(tmp.path, 'src.png'));
      await src.writeAsBytes(await _pngBytes(8, 600));

      final first = await cache.obtain(src.path);
      expect(first, isNotNull);
      expect(await first!.exists(), isTrue);
      // PNG magic.
      final head = (await first.readAsBytes()).take(4).toList();
      expect(head, [0x89, 0x50, 0x4E, 0x47]);

      final second = await cache.obtain(src.path);
      expect(second!.path, first.path);
    });

    test('prunes the stale generation when the source changes', () async {
      final src = File(p.join(tmp.path, 'src.png'));
      await src.writeAsBytes(await _pngBytes(8, 600));
      final first = await cache.obtain(src.path);

      // Rewrite the source (new size -> new key) and re-obtain.
      await src.writeAsBytes(await _pngBytes(8, 300));
      final second = await cache.obtain(src.path);

      expect(second, isNotNull);
      expect(second!.path, isNot(first!.path));
      expect(await first.exists(), isFalse); // stale generation pruned
    });

    test('returns null for a missing or undecodable source', () async {
      expect(await cache.obtain(p.join(tmp.path, 'gone.png')), isNull);
      final junk = File(p.join(tmp.path, 'junk.png'));
      await junk.writeAsBytes(List.filled(64, 7));
      expect(await cache.obtain(junk.path), isNull);
    });

    test('TALL source: sidecar keeps native width and crops the TOP slice',
        () async {
      // A tall screenshot: the tile covers by WIDTH (topCenter), so the
      // sidecar must be the top slice at full width — the old height-only
      // bound shrank a 120x1200 source to 46x456 and the tile upscaled it
      // blurry. Top 200 rows red, rest blue.
      final src = File(p.join(tmp.path, 'tall.png'));
      await src.writeAsBytes(await _paintedPngBytes(
          120, 1200, (x, y) => y < 200 ? [255, 0, 0] : [0, 0, 255]));

      final f = await cache.obtain(src.path);
      final (w, h, rgba) = await _decode(f!);
      expect(w, 120); // native width kept (<= box width)
      expect(h, (120 * 456 / 620).round()); // box-aspect top crop
      // Every pixel is from the red TOP slice.
      for (var i = 0; i < rgba.length; i += 4) {
        expect(rgba[i], 255, reason: 'px ${i ~/ 4} not from the top slice');
        expect(rgba[i + 2], 0);
      }
    });

    test('WIDE source: sidecar crops a horizontally CENTERED slice at native '
        'height', () async {
      // A wide panorama: the tile covers by HEIGHT; the sidecar must be the
      // horizontally-centered slice. Left/right thirds green, middle yellow.
      final src = File(p.join(tmp.path, 'wide.png'));
      await src.writeAsBytes(await _paintedPngBytes(
          1200, 120,
          (x, y) => (x < 400 || x >= 800) ? [0, 255, 0] : [255, 255, 0]));

      final f = await cache.obtain(src.path);
      final (w, h, rgba) = await _decode(f!);
      expect(h, 120); // native height kept (<= box height)
      expect(w, (120 * 620 / 456).round()); // box-aspect centered crop
      // Every pixel is from the yellow CENTER band.
      for (var i = 0; i < rgba.length; i += 4) {
        expect(rgba[i], 255, reason: 'px ${i ~/ 4} not from the center band');
        expect(rgba[i + 1], 255);
        expect(rgba[i + 2], 0);
      }
    });

    test('bounds concurrent generation', () async {
      final paths = <String>[];
      for (var i = 0; i < 6; i++) {
        final f = File(p.join(tmp.path, 'src$i.png'));
        await f.writeAsBytes(await _pngBytes(8, 300 + i));
        paths.add(f.path);
      }
      final results =
          await Future.wait(paths.map((path) => cache.obtain(path)));
      expect(results.whereType<File>(), hasLength(6));
    });
  });
}
