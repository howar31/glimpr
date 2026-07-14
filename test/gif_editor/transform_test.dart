import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/gif_editor/transform.dart';

/// Build a w*h RGBA buffer whose pixel (x, y) encodes its position:
/// r = x, g = y, b = 7, a = 255 (positions must stay < 256).
Uint8List _grid(int w, int h) {
  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final o = (y * w + x) * 4;
      out[o] = x;
      out[o + 1] = y;
      out[o + 2] = 7;
      out[o + 3] = 255;
    }
  }
  return out;
}

List<int> _px(Uint8List rgba, int w, int x, int y) =>
    [for (var i = 0; i < 4; i++) rgba[(y * w + x) * 4 + i]];

void main() {
  group('cropRect', () {
    test('extracts the exact sub-rectangle', () {
      final src = _grid(8, 6);
      final out = cropRect(src, 8, 6, 2, 1, 4, 3);
      expect(out.length, 4 * 3 * 4);
      expect(_px(out, 4, 0, 0), [2, 1, 7, 255]);
      expect(_px(out, 4, 3, 2), [5, 3, 7, 255]);
    });

    test('full-frame crop is identity', () {
      final src = _grid(5, 4);
      expect(cropRect(src, 5, 4, 0, 0, 5, 4), src);
    });
  });

  group('flip', () {
    test('flipH mirrors columns and is an involution', () {
      final src = _grid(6, 3);
      final flipped = flipH(src, 6, 3);
      expect(_px(flipped, 6, 0, 0), [5, 0, 7, 255]);
      expect(_px(flipped, 6, 5, 2), [0, 2, 7, 255]);
      expect(flipH(flipped, 6, 3), src);
    });

    test('flipV mirrors rows and is an involution', () {
      final src = _grid(4, 5);
      final flipped = flipV(src, 4, 5);
      expect(_px(flipped, 4, 0, 0), [0, 4, 7, 255]);
      expect(flipV(flipped, 4, 5), src);
    });
  });

  group('rotate', () {
    test('rotate90cw maps (x,y) to (h-1-y, x)', () {
      final src = _grid(4, 3); // out is 3x4
      final out = rotate90cw(src, 4, 3);
      // src (0,0) lands at out (2,0).
      expect(_px(out, 3, 2, 0), [0, 0, 7, 255]);
      // src (3,2) lands at out (0,3).
      expect(_px(out, 3, 0, 3), [3, 2, 7, 255]);
    });

    test('four clockwise quarter turns are identity', () {
      final src = _grid(5, 3);
      var cur = rotate90cw(src, 5, 3);
      cur = rotate90cw(cur, 3, 5);
      cur = rotate90cw(cur, 5, 3);
      cur = rotate90cw(cur, 3, 5);
      expect(cur, src);
    });

    test('ccw undoes cw and 180 equals double flip', () {
      final src = _grid(6, 4);
      expect(rotate90ccw(rotate90cw(src, 6, 4), 4, 6), src);
      expect(rotate180(src, 6, 4), flipV(flipH(src, 6, 4), 6, 4));
    });
  });

  group('drawBorder', () {
    test('paints the band and leaves the interior alone', () {
      final src = _grid(8, 6);
      final out = drawBorder(src, 8, 6, 2, 0xFF102030);
      expect(_px(out, 8, 0, 0), [16, 32, 48, 255]);
      expect(_px(out, 8, 7, 5), [16, 32, 48, 255]);
      expect(_px(out, 8, 1, 3), [16, 32, 48, 255]); // left band, row middle
      expect(_px(out, 8, 4, 1), [16, 32, 48, 255]); // top band
      expect(_px(out, 8, 4, 3), [4, 3, 7, 255]); // interior untouched
    });

    test('width clamps to half the short side', () {
      final src = _grid(4, 4);
      final out = drawBorder(src, 4, 4, 99, 0xFFFFFFFF);
      // Clamped to 2: everything is border on a 4x4.
      for (var y = 0; y < 4; y++) {
        for (var x = 0; x < 4; x++) {
          expect(_px(out, 4, x, y), [255, 255, 255, 255]);
        }
      }
    });
  });

  group('resizeBilinear', () {
    test('solid input stays solid at any size', () {
      final src = Uint8List(4 * 4 * 4);
      for (var i = 0; i < 16; i++) {
        src[i * 4] = 90;
        src[i * 4 + 1] = 140;
        src[i * 4 + 2] = 200;
        src[i * 4 + 3] = 255;
      }
      final out = resizeBilinear(src, 4, 4, 7, 3);
      expect(out.length, 7 * 3 * 4);
      for (var i = 0; i < 7 * 3; i++) {
        expect(_px(out, 7, i % 7, i ~/ 7), [90, 140, 200, 255]);
      }
    });

    test('downscaling a black/white pair blends toward the middle', () {
      final src = Uint8List.fromList([
        0, 0, 0, 255, //
        255, 255, 255, 255, //
      ]);
      final out = resizeBilinear(src, 2, 1, 1, 1);
      final v = out[0];
      expect(v, inInclusiveRange(100, 155));
      expect(out[3], 255);
    });

    test('identity size returns equal pixels', () {
      final src = _grid(5, 4);
      expect(resizeBilinear(src, 5, 4, 5, 4), src);
    });
  });
}
