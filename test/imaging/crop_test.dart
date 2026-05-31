import 'dart:typed_data';
import 'dart:ui' show Rect;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:glimpr/imaging/crop.dart';

void main() {
  Uint8List makeSourcePng() {
    final im = img.Image(width: 200, height: 100);
    for (var y = 0; y < 100; y++) {
      for (var x = 0; x < 200; x++) {
        im.setPixelRgba(x, y, x < 100 ? 255 : 0, 0, x < 100 ? 0 : 255, 255);
      }
    }
    return Uint8List.fromList(img.encodePng(im));
  }

  test('crops with scaleFactor 2.0 to native pixels and keeps the right region', () {
    final src = makeSourcePng();
    final out = cropToSelection(
      pngBytes: src, scaleFactor: 2.0, selection: const Rect.fromLTWH(50, 0, 50, 50));
    final decoded = img.decodePng(out)!;
    expect(decoded.width, 100);
    expect(decoded.height, 100);
    final p = decoded.getPixel(10, 10);
    expect(p.r, 0);
    expect(p.b, 255);
  });

  test('clamps a selection that exceeds the image bounds', () {
    final src = makeSourcePng();
    final out = cropToSelection(
      pngBytes: src, scaleFactor: 2.0, selection: const Rect.fromLTWH(90, 40, 50, 50));
    final decoded = img.decodePng(out)!;
    expect(decoded.width, 20);
    expect(decoded.height, 20);
  });

  test('encodes JPEG when quality is provided', () {
    final src = makeSourcePng();
    final out = cropToSelection(
      pngBytes: src, scaleFactor: 1.0, selection: const Rect.fromLTWH(0, 0, 50, 50), jpegQuality: 90);
    expect(img.decodeJpg(out), isNotNull);
  });
}
