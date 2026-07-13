import 'dart:typed_data';

/// A 256-entry GIF palette plus RGB→index mapping.
///
/// S1 ships the fixed 6x6x6 cube (216 colors, exact for full-intensity
/// primaries) padded with grays; S2 replaces the construction with a
/// per-document median-cut quantizer behind this same class, so callers and
/// the writer never change.
class Palette {
  Palette._(this.rgb);

  /// Index reserved for the transparent pixel (GCE transparent color index).
  static const int transparentIndex = 255;

  /// 256 * 3 bytes, RGB per entry. Entry [transparentIndex] is a slot the
  /// mapper never returns for opaque pixels.
  final Uint8List rgb;

  /// The uniform web-style cube: levels 0/51/102/153/204/255 per channel at
  /// indices 0..215, a gray ramp at 216..254, and the transparent slot at 255.
  factory Palette.fixed216() {
    final rgb = Uint8List(256 * 3);
    const levels = [0, 51, 102, 153, 204, 255];
    var i = 0;
    for (final r in levels) {
      for (final g in levels) {
        for (final b in levels) {
          rgb[i * 3] = r;
          rgb[i * 3 + 1] = g;
          rgb[i * 3 + 2] = b;
          i++;
        }
      }
    }
    // 39 grays between the cube's 51-steps (216..254).
    for (var g = 0; g < 39; g++) {
      final v = ((g + 1) * 255 / 40).round();
      rgb[(216 + g) * 3] = v;
      rgb[(216 + g) * 3 + 1] = v;
      rgb[(216 + g) * 3 + 2] = v;
    }
    return Palette._(rgb);
  }

  /// Nearest palette index for an opaque RGB pixel (never the transparent
  /// slot). The fixed cube quantizes each channel to its closest level.
  int indexOf(int r, int g, int b) {
    final qr = ((r * 5) + 127) ~/ 255;
    final qg = ((g * 5) + 127) ~/ 255;
    final qb = ((b * 5) + 127) ~/ 255;
    return qr * 36 + qg * 6 + qb;
  }
}
