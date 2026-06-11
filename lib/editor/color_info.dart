import 'dart:math' as math;
import 'dart:ui';

/// Eyedropper readout formatting (pure, unit-tested): while the color picker
/// is active the loupe shows the aimed pixel's color as HEX / RGB / HSL.
/// Alpha is omitted on purpose — captures are opaque and the sample discards
/// it (the tool keeps its own alpha).

int _ch(double v) => (v * 255.0).round() & 0xff;

String hexOf(Color c) =>
    '#${_ch(c.r).toRadixString(16).padLeft(2, '0')}'
            '${_ch(c.g).toRadixString(16).padLeft(2, '0')}'
            '${_ch(c.b).toRadixString(16).padLeft(2, '0')}'
        .toUpperCase();

String rgbOf(Color c) => '${_ch(c.r)}, ${_ch(c.g)}, ${_ch(c.b)}';

({int h, int s, int l}) _hsl(Color c) {
  final r = c.r, g = c.g, b = c.b;
  final maxC = math.max(r, math.max(g, b));
  final minC = math.min(r, math.min(g, b));
  final l = (maxC + minC) / 2;
  final d = maxC - minC;
  var h = 0.0, s = 0.0;
  if (d > 0) {
    s = d / (1 - (2 * l - 1).abs());
    if (maxC == r) {
      h = 60 * (((g - b) / d) % 6);
    } else if (maxC == g) {
      h = 60 * (((b - r) / d) + 2);
    } else {
      h = 60 * (((r - g) / d) + 4);
    }
  }
  return (h: h.round(), s: (s * 100).round(), l: (l * 100).round());
}

/// Display form, e.g. `199° 94% 67%`.
String hslOf(Color c) {
  final v = _hsl(c);
  return '${v.h}° ${v.s}% ${v.l}%';
}

/// Clipboard forms are CSS-ready (the readout shows the compact display
/// forms above; hexOf is already CSS-ready).
String rgbCssOf(Color c) => 'rgb(${rgbOf(c)})';

String hslCssOf(Color c) {
  final v = _hsl(c);
  return 'hsl(${v.h}, ${v.s}%, ${v.l}%)';
}
