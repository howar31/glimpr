import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'draw_style.dart' show HighlighterTexture;

/// The highlighter's brush textures: each textured style is a recipe baked
/// ONCE into a white-with-alpha band image, which the painter then TILES
/// along each stroke as a single textured ribbon (see ribbon.dart). Baking
/// keeps the per-frame work to one textured draw per stroke, whatever the
/// recipe draws.
///
/// Recipes paint WHITE; only the alpha carries the look (the painter tints).
/// Band space: x = 0..length along the stroke, y = 0..width across it. The
/// band must be SEAMLESS in x (it repeats along the stroke): anything drawn
/// near an end is drawn again one length over (see [_wrapX]).

/// Band texture size in texels. The width maps onto the marker band; the
/// length is one tile along the stroke (= length/width band widths). Tunable.
const int kBrushBandLength = 2048;
const int kBrushBandWidth = 128;

/// Ink never fully opaque: the marker look keeps a hint of the page.
const double _kMaxAlpha = 0.95;

/// Fixed bake seed per texture, so every engine bakes identical bands.
int brushBakeSeed(HighlighterTexture t) => 0x9E37 * (t.index + 1) + 11;

/// The tiling phase (in texels along the band) for a stroke [seed]: strokes
/// start at different points of the tile, so they differ while each stays
/// fixed (the seed is carried by the drawable).
double brushPhase(int seed) =>
    (((seed * 2654435761) % kBrushBandLength) + kBrushBandLength) %
    kBrushBandLength *
    1.0;

ui.Color _white(double a) =>
    const ui.Color(0xFFFFFFFF).withValues(alpha: a.clamp(0.0, _kMaxAlpha));

/// Run [draw] at x offsets 0, -length and +length so shapes crossing either
/// end wrap around: the tile stays seamless.
void _wrapX(ui.Canvas canvas, double length, void Function() draw) {
  for (final dx in [0.0, -length, length]) {
    canvas.save();
    canvas.translate(dx, 0);
    draw();
    canvas.restore();
  }
}

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

/// Paint the band of [texture] ([length] x [width]) with [seed]. Clean has no
/// band (the painter strokes a plain path) and asserts here.
void paintBrushBand(
  ui.Canvas canvas,
  HighlighterTexture texture,
  double length,
  double width,
  int seed,
) {
  switch (texture) {
    case HighlighterTexture.clean:
      assert(false, 'clean is not a baked texture');
    case HighlighterTexture.streaks:
      paintStreakBand(canvas, length, width, seed);
    case HighlighterTexture.grain:
      paintGrainBand(canvas, length, width, seed);
    case HighlighterTexture.bristle:
      paintBristleBand(canvas, length, width, seed);
    case HighlighterTexture.chisel:
      paintChiselBand(canvas, length, width, seed);
  }
}

/// Streaks: a felt-tip marker. Many fine streaks across the band, each with
/// its own intensity plus a periodic lengthwise variation and ink-darker long
/// edges.
void paintStreakBand(ui.Canvas canvas, double length, double width, int seed) {
  // ---- tunable constants (iterate in-app) --------------------------------
  const streakCount = 18; // felt-tip streak lines across the band
  const streakAmp = 0.4; // per-streak intensity variation
  const lengthAmp = 0.22; // along-stroke variation (per-streak gradient)
  const edgeInk = 0.7; // extra darkening at the long edges

  final noise = MarkerNoise(seed);
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
    // Ends share a stop so the tile is seamless along the stroke.
    paint
      ..strokeWidth = bandStep * 1.3 // overlap so there are no seams
      ..shader = ui.Gradient.linear(s0, s1, [
        _white(la(0)),
        _white(la(6)),
        _white(la(12)),
        _white(la(0)),
      ], const [0.0, 0.33, 0.66, 1.0]);
    canvas.drawLine(s0, s1, paint);
  }
}

/// Grain: a wax crayon on rough paper. A translucent body with paper grain
/// punched out of it (holes, denser and larger near the long edges so they
/// fray softly) plus scattered darker specks where the wax caught.
void paintGrainBand(ui.Canvas canvas, double length, double width, int seed) {
  // ---- tunable constants (iterate in-app) --------------------------------
  const bodyAlpha = 0.74; // the un-grained wax coverage
  const holesPerWidth = 160; // paper-grain dropouts per band-width of length
  const edgeHolesPerWidth = 56; // extra dropouts hugging each long edge
  const specksPerWidth = 70; // darker wax specks
  const edgeZone = 0.14; // fraction of the width the edge fray reaches

  final r = math.Random(seed);
  final tiles = length / width;
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, length, width),
    ui.Paint()..color = _white(bodyAlpha),
  );
  final hole = ui.Paint()..blendMode = ui.BlendMode.dstOut;
  void punch(double x, double y, double s, double a) {
    hole.color = ui.Color.fromRGBO(0, 0, 0, a);
    final rect =
        ui.Rect.fromCenter(center: ui.Offset(x, y), width: s, height: s * 0.7);
    _wrapX(canvas, length, () => canvas.drawOval(rect, hole));
  }

  for (var i = 0; i < holesPerWidth * tiles; i++) {
    punch(
      r.nextDouble() * length,
      r.nextDouble() * width,
      1.5 + r.nextDouble() * 4.5,
      0.35 + r.nextDouble() * 0.65,
    );
  }
  // Edge fray: holes biased toward each long edge, bigger right at the edge.
  final zone = width * edgeZone;
  for (var i = 0; i < edgeHolesPerWidth * tiles; i++) {
    final d = math.pow(r.nextDouble(), 2.0) * zone; // most near the edge
    final top = r.nextBool();
    final y = top ? d : width - d;
    final s = 3 + (1 - d / zone) * 7 + r.nextDouble() * 3;
    punch(r.nextDouble() * length, y, s, 0.6 + r.nextDouble() * 0.4);
  }
  // Darker specks where the wax caught the paper.
  final speck = ui.Paint()..isAntiAlias = true;
  for (var i = 0; i < specksPerWidth * tiles; i++) {
    speck.color = _white(bodyAlpha + 0.08 + r.nextDouble() * 0.16);
    final s = 1.5 + r.nextDouble() * 3;
    final rect = ui.Rect.fromCenter(
      center: ui.Offset(r.nextDouble() * length, r.nextDouble() * width),
      width: s,
      height: s,
    );
    _wrapX(canvas, length, () => canvas.drawOval(rect, speck));
  }
}

/// Bristle: a flat brush. A few thick bristle strands with gaps between them,
/// each wandering gently along the stroke (whole cycles per tile, so the tile
/// is seamless), thinning and drying out at random spots.
void paintBristleBand(ui.Canvas canvas, double length, double width, int seed) {
  // ---- tunable constants (iterate in-app) --------------------------------
  const strandCount = 6; // thick strands across the band
  const fillMin = 0.72, fillMax = 1.05; // strand thickness as a slot fraction
  const wanderAmp = 0.22; // sideways wander as a slot fraction
  const samples = 96; // polyline samples along the tile
  const dryPerWidth = 0.09; // dry-out spots per strand per band-width
  const dryLenMin = 0.5, dryLenMax = 1.4; // dry spot length in band widths

  final r = math.Random(seed);
  final slot = width / strandCount;
  final tiles = length / width;
  final paint = ui.Paint()
    ..isAntiAlias = true
    ..style = ui.PaintingStyle.stroke
    ..strokeCap = ui.StrokeCap.butt
    ..strokeJoin = ui.StrokeJoin.round;
  final dry = ui.Paint()..blendMode = ui.BlendMode.dstOut;
  for (var i = 0; i < strandCount; i++) {
    final centre = slot * (i + 0.5) + (r.nextDouble() - 0.5) * slot * 0.3;
    final thick = slot * (fillMin + r.nextDouble() * (fillMax - fillMin));
    // Two sine waves with whole numbers of cycles per tile: seamless wander.
    final k1 = 3 + r.nextInt(4), k2 = 7 + r.nextInt(6);
    final p1 = r.nextDouble() * math.pi * 2, p2 = r.nextDouble() * math.pi * 2;
    final amp = slot * wanderAmp;
    final path = ui.Path();
    for (var s = 0; s <= samples; s++) {
      final x = length * s / samples;
      final t = x / length * math.pi * 2;
      final y = centre +
          amp * (0.7 * math.sin(k1 * t + p1) + 0.3 * math.sin(k2 * t + p2));
      if (s == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    paint
      ..strokeWidth = thick
      ..color = _white(0.62 + r.nextDouble() * 0.3);
    canvas.drawPath(path, paint);
    // Dry-out spots: soft lengthwise fades punched out of this strand.
    final spots = (dryPerWidth * tiles).round();
    for (var d = 0; d < spots; d++) {
      final x = r.nextDouble() * length;
      final len = width * (dryLenMin + r.nextDouble() * (dryLenMax - dryLenMin));
      final depth = 0.45 + r.nextDouble() * 0.4;
      final rect = ui.Rect.fromLTWH(x - len / 2, centre - slot, len, slot * 2);
      dry.shader = ui.Gradient.linear(
        ui.Offset(x - len / 2, 0),
        ui.Offset(x + len / 2, 0),
        [
          const ui.Color(0x00000000),
          ui.Color.fromRGBO(0, 0, 0, depth),
          const ui.Color(0x00000000),
        ],
        const [0.0, 0.5, 1.0],
      );
      _wrapX(canvas, length, () => canvas.drawRect(rect, dry));
    }
  }
}

/// Chisel: a broad chisel-tip marker held at an angle. Ink is densest along
/// one long edge (a crisp pressed edge) and thins across the band, with a
/// faint lengthwise ripple where the tip skipped.
void paintChiselBand(ui.Canvas canvas, double length, double width, int seed) {
  // ---- tunable constants (iterate in-app) --------------------------------
  const denseAlpha = 0.95; // at the pressed edge
  const lightAlpha = 0.34; // at the trailing edge
  const edgeLine = 0.04; // crisp pressed-edge band, fraction of the width
  const ripplesPerWidth = 0.9; // faint lengthwise skips per band-width
  const rippleAlpha = 0.16; // how much a skip lifts the ink

  final r = math.Random(seed);
  final rect = ui.Rect.fromLTWH(0, 0, length, width);
  canvas.drawRect(
    rect,
    ui.Paint()
      ..shader = ui.Gradient.linear(
        ui.Offset(0, 0),
        ui.Offset(0, width),
        [_white(denseAlpha), _white(denseAlpha * 0.8), _white(lightAlpha)],
        const [0.0, 0.35, 1.0],
      ),
  );
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, length, width * edgeLine),
    ui.Paint()..color = _white(denseAlpha),
  );
  final skip = ui.Paint()..blendMode = ui.BlendMode.dstOut;
  final ripples = (ripplesPerWidth * length / width).round();
  for (var i = 0; i < ripples; i++) {
    final x = r.nextDouble() * length;
    final w = width * (0.05 + r.nextDouble() * 0.17);
    skip.shader = ui.Gradient.linear(
      ui.Offset(x - w, 0),
      ui.Offset(x + w, 0),
      [
        const ui.Color(0x00000000),
        ui.Color.fromRGBO(0, 0, 0, rippleAlpha * (0.5 + r.nextDouble() * 0.5)),
        const ui.Color(0x00000000),
      ],
      const [0.0, 0.5, 1.0],
    );
    final strip = ui.Rect.fromLTWH(x - w, 0, w * 2, width);
    _wrapX(canvas, length, () => canvas.drawRect(strip, skip));
  }
}

/// Bake the band of [texture] (synchronous; needs a live engine).
ui.Image bakeBrushBand(HighlighterTexture texture) {
  final rec = ui.PictureRecorder();
  paintBrushBand(
    ui.Canvas(rec),
    texture,
    kBrushBandLength.toDouble(),
    kBrushBandWidth.toDouble(),
    brushBakeSeed(texture),
  );
  final pic = rec.endRecording();
  final img = pic.toImageSync(kBrushBandLength, kBrushBandWidth);
  pic.dispose();
  return img;
}

/// Per-engine cache of the baked bands (a ui.Image never crosses engines, so
/// every overlay engine bakes its own on first use). Kept for the engine's
/// lifetime: one small image per textured style.
class BrushTextures {
  BrushTextures._();
  static final BrushTextures instance = BrushTextures._();

  final _bands = <HighlighterTexture, ui.Image>{};

  /// The band of [texture], baked on first use.
  ui.Image band(HighlighterTexture texture) =>
      _bands.putIfAbsent(texture, () => bakeBrushBand(texture));

  int get bakedCount => _bands.length;

  @visibleForTesting
  void reset() {
    for (final img in _bands.values) {
      img.dispose();
    }
    _bands.clear();
  }
}
