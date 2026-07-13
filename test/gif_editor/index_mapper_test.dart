import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/gif_editor/encode/index_mapper.dart';
import 'package:glimpr/gif_editor/encode/palette.dart';

Uint8List _row(List<List<int>> pixels) {
  final out = Uint8List(pixels.length * 4);
  for (var i = 0; i < pixels.length; i++) {
    out[i * 4] = pixels[i][0];
    out[i * 4 + 1] = pixels[i][1];
    out[i * 4 + 2] = pixels[i][2];
    out[i * 4 + 3] = pixels[i].length > 3 ? pixels[i][3] : 255;
  }
  return out;
}

/// A palette holding exactly black and white (forces visible quantization).
Palette _bwPalette() => Palette.medianCut([
      _row([
        [0, 0, 0],
        [255, 255, 255],
      ])
    ]);

void main() {
  group('mapFrameToIndices plain', () {
    test('matches palette.indexOf per pixel; transparent maps to the slot',
        () {
      final rgba = _row([
        [255, 0, 0],
        [0, 255, 0, 0], // transparent
        [12, 34, 56],
        [200, 100, 50],
      ]);
      final pal = Palette.medianCut([rgba]);
      final idx = mapFrameToIndices(rgba, 4, 1, pal, dither: false);
      expect(idx[0], pal.indexOf(255, 0, 0));
      expect(idx[1], Palette.transparentIndex);
      expect(idx[2], pal.indexOf(12, 34, 56));
      expect(idx[3], pal.indexOf(200, 100, 50));
    });
  });

  group('mapFrameToIndices dither', () {
    test('exactly representable image is identical to plain mapping', () {
      // 8x2 alternating two colors, both in the palette: zero error anywhere.
      final pixels = <List<int>>[
        for (var i = 0; i < 16; i++)
          i.isEven ? [10, 20, 30] : [200, 100, 50],
      ];
      final rgba = _row(pixels);
      final pal = Palette.medianCut([rgba]);
      final plain = mapFrameToIndices(rgba, 8, 2, pal, dither: false);
      final dithered = mapFrameToIndices(rgba, 8, 2, pal, dither: true);
      expect(dithered, plain);
    });

    test('preserves the local average on a flat tone (plain cannot)', () {
      // A 32x32 solid gray-100 image against a black/white palette: plain
      // maps everything to black (mean 0); dithering must mix so the mean
      // reconstructed value tracks the source.
      const w = 32, h = 32;
      final rgba = Uint8List(w * h * 4);
      for (var i = 0; i < w * h; i++) {
        rgba[i * 4] = 100;
        rgba[i * 4 + 1] = 100;
        rgba[i * 4 + 2] = 100;
        rgba[i * 4 + 3] = 255;
      }
      final pal = _bwPalette();
      final plain = mapFrameToIndices(rgba, w, h, pal, dither: false);
      final dithered = mapFrameToIndices(rgba, w, h, pal, dither: true);
      double meanOf(Uint8List indices) {
        var sum = 0;
        for (final i in indices) {
          sum += pal.rgb[i * 3]; // gray palette: r == g == b
        }
        return sum / indices.length;
      }

      expect(meanOf(plain), 0);
      expect((meanOf(dithered) - 100).abs(), lessThan(10));
    });

    test('transparent pixels stay transparent and block error propagation',
        () {
      // gray-100 -> transparent -> gray-100. With black/white entries the
      // first pixel's +100 error dies at the transparent pixel, so the third
      // maps to black exactly like the first. If the error leaked through,
      // 100 + 43.75 crosses the midpoint and the third would come out white.
      final rgba = _row([
        [100, 100, 100],
        [0, 0, 0, 0],
        [100, 100, 100],
      ]);
      final pal = _bwPalette();
      final idx = mapFrameToIndices(rgba, 3, 1, pal, dither: true);
      final black = pal.indexOf(0, 0, 0);
      expect(idx[0], black);
      expect(idx[1], Palette.transparentIndex);
      expect(idx[2], black);
    });
  });
}
