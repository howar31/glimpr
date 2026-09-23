import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;

/// The highlighter's brush texture: the felt-tip streak recipe baked ONCE into
/// a white-with-alpha band image, which the painter then maps along each
/// stroke as a single textured ribbon (see ribbon.dart). Baking keeps the
/// per-frame work to one textured draw per stroke, independent of how the
/// texture is composed.

/// Band texture size in texels: the length is stretched over the stroke's arc
/// length, the width over the marker band. Tunable.
const int kBrushBandLength = 1024;
const int kBrushBandWidth = 128;

/// How many pre-baked variants a stroke's seed picks from, so strokes differ
/// while each one stays fixed (the seed is carried by the drawable).
const int kBrushVariants = 4;

/// The variant index for [seed] (seeds may be negative).
int brushVariant(int seed) =>
    ((seed % kBrushVariants) + kBrushVariants) % kBrushVariants;

/// The bake seed of a variant: fixed, so every engine bakes identical bands.
int brushVariantSeed(int variant) => 0x9E37 * (variant + 1) + 11;

/// Smooth, deterministic value noise for the procedural marker texture — same
/// seed always yields the same curve, so a highlighter never shimmers on repaint.
class MarkerNoise {
  late final List<double> _g;
  MarkerNoise(int seed) {
    final r = math.Random(seed);
    _g = List.generate(256, (_) => r.nextDouble());
  }
  double call(double x) {
    final i = x.floor();
    final f = x - i;
    final a = _g[((i % 256) + 256) % 256];
    final b = _g[(((i + 1) % 256) + 256) % 256];
    final u = f * f * (3 - 2 * f); // smoothstep
    return a + (b - a) * u;
  }
}

/// Paints the felt-tip streak recipe as a straight WHITE band from (0, w/2)
/// to ([length], w/2), [width] wide: a few long streaks offset across the
/// band, each with its own intensity plus a 3-stop lengthwise variation and
/// ink-darker long edges. Alpha carries the texture; the painter tints it.
void paintStreakBand(ui.Canvas canvas, double length, double width, int seed) {
  // ---- tunable constants (iterate in-app) --------------------------------
  const streakCount = 18; // felt-tip streak lines across the band
  const streakAmp = 0.4; // per-streak intensity variation
  const lengthAmp = 0.22; // along-stroke variation (per-streak gradient)
  const edgeInk = 0.7; // extra darkening at the long edges

  final noise = MarkerNoise(seed);
  ui.Color withA(double a) =>
      const ui.Color(0xFFFFFFFF).withValues(alpha: a.clamp(0.0, 0.95));
  final paint = ui.Paint()
    ..isAntiAlias = true
    ..style = ui.PaintingStyle.stroke
    ..strokeCap = ui.StrokeCap.butt;
  final bandStep = width / streakCount;
  for (var i = 0; i < streakCount; i++) {
    final tt = (i + 0.5) / streakCount; // 0..1 across the band
    final y = width / 2 + (tt - 0.5) * width;
    var base = (1 - streakAmp) + streakAmp * noise(i * 1.7 + 3);
    final edge = math.pow((tt - 0.5).abs() * 2, 2.2).toDouble();
    base *= 1 + edgeInk * edge; // ink-darker long edges
    double la(double k) =>
        base * ((1 - lengthAmp) + lengthAmp * noise(i * 0.5 + k));
    final s0 = ui.Offset(0, y);
    final s1 = ui.Offset(length, y);
    paint
      ..strokeWidth = bandStep * 1.3 // overlap so there are no seams
      ..shader = ui.Gradient.linear(s0, s1, [
        withA(la(0)),
        withA(la(6)),
        withA(la(12)),
      ], const [0.0, 0.5, 1.0]);
    canvas.drawLine(s0, s1, paint);
  }
}

/// Bake the band texture of [variant] (synchronous; needs a live engine).
ui.Image bakeBrushBand(int variant) {
  final rec = ui.PictureRecorder();
  paintStreakBand(
    ui.Canvas(rec),
    kBrushBandLength.toDouble(),
    kBrushBandWidth.toDouble(),
    brushVariantSeed(variant),
  );
  final pic = rec.endRecording();
  final img = pic.toImageSync(kBrushBandLength, kBrushBandWidth);
  pic.dispose();
  return img;
}

/// Per-engine cache of the baked bands (a ui.Image never crosses engines, so
/// every overlay engine bakes its own on first use). Kept for the engine's
/// lifetime: a handful of small images.
class BrushTextures {
  BrushTextures._();
  static final BrushTextures instance = BrushTextures._();

  final _bands = <int, ui.Image>{};

  /// The band for a stroke [seed], baked on first use.
  ui.Image band(int seed) {
    final v = brushVariant(seed);
    return _bands.putIfAbsent(v, () => bakeBrushBand(v));
  }

  int get bakedCount => _bands.length;

  @visibleForTesting
  void reset() {
    for (final img in _bands.values) {
      img.dispose();
    }
    _bands.clear();
  }
}
