import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/gif_editor/encode/palette.dart';

/// One RGBA buffer holding every color in [colors] once (alpha 255).
Uint8List _bufferOf(List<List<int>> colors) {
  final out = Uint8List(colors.length * 4);
  for (var i = 0; i < colors.length; i++) {
    out[i * 4] = colors[i][0];
    out[i * 4 + 1] = colors[i][1];
    out[i * 4 + 2] = colors[i][2];
    out[i * 4 + 3] = 255;
  }
  return out;
}

List<int> _entry(Palette p, int idx) =>
    [p.rgb[idx * 3], p.rgb[idx * 3 + 1], p.rgb[idx * 3 + 2]];

void main() {
  group('Palette.medianCut', () {
    test('reproduces <=255 distinct colors exactly', () {
      // 200 distinct colors spread across the cube.
      final colors = <List<int>>[
        for (var i = 0; i < 200; i++)
          [(i * 37) & 0xFF, (i * 91) & 0xFF, (i * 53) & 0xFF],
      ];
      final seen = <int>{
        for (final c in colors) (c[0] << 16) | (c[1] << 8) | c[2],
      };
      final p = Palette.medianCut([_bufferOf(colors)]);
      for (final c in colors) {
        final idx = p.indexOf(c[0], c[1], c[2]);
        expect(idx, lessThan(Palette.transparentIndex));
        expect(_entry(p, idx), c, reason: 'color $c must map exactly');
      }
      expect(seen.length, 200); // sanity: the fixture really had 200 colors
    });

    test('caps at 255 opaque entries and never returns the transparent slot',
        () {
      // A 32x32x8 sweep: 8192 distinct colors, forces real median-cut splits.
      final colors = <List<int>>[
        for (var r = 0; r < 32; r++)
          for (var g = 0; g < 32; g++)
            for (var b = 0; b < 8; b++) [r * 8, g * 8, b * 32],
      ];
      final p = Palette.medianCut([_bufferOf(colors)]);
      final rnd = Random(7);
      for (var i = 0; i < 2000; i++) {
        final idx =
            p.indexOf(rnd.nextInt(256), rnd.nextInt(256), rnd.nextInt(256));
        expect(idx, inInclusiveRange(0, Palette.transparentIndex - 1));
      }
    });

    test('beats fixed216 on a smooth gradient (mean squared error)', () {
      // A gray-to-blue gradient: fixed216 has only 6 levels per channel here,
      // a dedicated palette should carry far more of them.
      final colors = <List<int>>[
        for (var i = 0; i < 1024; i++)
          [i ~/ 4, i ~/ 4, min(255, i ~/ 4 + 64)],
      ];
      final buf = _bufferOf(colors);
      final adaptive = Palette.medianCut([buf]);
      final fixed = Palette.fixed216();
      double mse(Palette p) {
        var sum = 0.0;
        for (final c in colors) {
          final e = _entry(p, p.indexOf(c[0], c[1], c[2]));
          sum += pow(e[0] - c[0], 2) +
              pow(e[1] - c[1], 2) +
              pow(e[2] - c[2], 2).toDouble();
        }
        return sum / colors.length;
      }

      expect(mse(adaptive), lessThan(mse(fixed) / 4));
    });

    test('ignores transparent pixels when sampling', () {
      // One opaque red pixel + many transparent green ones: green must not
      // steal palette entries (a transparent pixel has no color).
      final buf = Uint8List(64 * 4);
      buf[0] = 255;
      buf[3] = 255; // opaque red
      for (var i = 1; i < 64; i++) {
        buf[i * 4 + 1] = 255; // green, alpha 0
      }
      final p = Palette.medianCut([buf]);
      final idx = p.indexOf(255, 0, 0);
      expect(_entry(p, idx), [255, 0, 0]);
      // Nearest match for green is judged against the sampled set, so it
      // resolves to red (the only sampled color), not green.
      final gIdx = p.indexOf(0, 255, 0);
      expect(_entry(p, gIdx), [255, 0, 0]);
    });

    test('empty sample set falls back to a usable palette', () {
      final allTransparent = Uint8List(16 * 4); // alpha 0 everywhere
      final p = Palette.medianCut([allTransparent]);
      final idx = p.indexOf(128, 128, 128);
      expect(idx, inInclusiveRange(0, Palette.transparentIndex - 1));
    });

    test('is deterministic across runs', () {
      final colors = <List<int>>[
        for (var i = 0; i < 5000; i++)
          [(i * 17) & 0xFF, (i * 29) & 0xFF, (i * 41) & 0xFF],
      ];
      final a = Palette.medianCut([_bufferOf(colors)]);
      final b = Palette.medianCut([_bufferOf(colors)]);
      expect(a.rgb, b.rgb);
    });

    test('honors sampleStride', () {
      // Stride 2 sees only even pixels: the odd-pixel color must not appear.
      final buf = _bufferOf([
        [10, 20, 30],
        [200, 100, 50],
        [10, 20, 30],
        [200, 100, 50],
      ]);
      final p = Palette.medianCut([buf], sampleStride: 2);
      final idx = p.indexOf(200, 100, 50);
      expect(_entry(p, idx), [10, 20, 30]);
    });
  });
}
