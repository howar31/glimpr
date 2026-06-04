import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'draw_style.dart';
import 'drawable.dart';
import 'text_metrics.dart';

/// Smooth, deterministic value noise for the procedural marker texture — same
/// seed always yields the same curve, so a highlighter never shimmers on repaint.
class _MarkerNoise {
  late final List<double> _g;
  _MarkerNoise(int seed) {
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

/// Paints a straight highlighter band from [points].first to [points].last in
/// [style], rendering the style's [HighlighterTexture]. Translucent srcOver only
/// (no multiply — it vanishes on dark screenshots); honours the colour's own
/// alpha. Reused by the painter and the toolbar's texture-preview chips.
///
/// Tunables for in-app iteration are grouped near the top.
void paintHighlighterStroke(
  Canvas canvas,
  List<Offset> points,
  DrawStyle style,
) {
  if (points.isEmpty) return;
  final start = points.first;
  final end = points.last;
  final w = style.strokeWidth * 5; // wide marker band
  final color = style.color;
  final half = w / 2;

  if ((end - start).distance < 0.5) {
    canvas.drawCircle(
      start,
      half,
      Paint()
        ..color = color
        ..isAntiAlias = true,
    );
    return;
  }

  // Clean: a plain round-capped translucent band, no texture.
  if (style.texture == HighlighterTexture.clean) {
    canvas.drawLine(
      start,
      end,
      Paint()
        ..color = color
        ..strokeWidth = w
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke
        ..isAntiAlias = true,
    );
    return;
  }

  // ---- tunable constants (iterate in-app) --------------------------------
  const streakCount = 18; // felt-tip streak lines across the band — a COUNT, so
  // the look scales with width AND stays cheap (≈this many draws per stroke).
  const streakAmp = 0.4; // per-streak intensity variation
  const lengthAmp = 0.22; // along-stroke variation (per-streak gradient)
  const edgeInk = 0.7; // extra darkening at the long edges

  final dir = end - start;
  final len = dir.distance;
  final u = dir / len; // unit along axis
  final n = Offset(-u.dy, u.dx); // unit normal
  final seed =
      (start.dx * 131 + start.dy * 557 + end.dx * 1289 + end.dy * 2741).round();
  final noise = _MarkerNoise(seed);
  final baseA = color.a; // the chosen alpha (0..1)
  Color withA(double a) => color.withValues(alpha: a.clamp(0.0, 0.95));

  // Build the band from a FEW long streak lines (≈streakCount draws) instead of
  // a per-pixel scanline×segment grid (that was ~10k+ drawLine calls per stroke
  // and made the editor janky). Each streak spans the full length at its own
  // intensity, with a 3-stop gradient along it for felt-tip lengthwise variation.
  final paint = Paint()
    ..isAntiAlias = true
    ..strokeCap = StrokeCap.butt;
  final bandStep = w / streakCount;
  for (var i = 0; i < streakCount; i++) {
    final t = (i + 0.5) / streakCount; // 0..1 across the band
    final off = (t - 0.5) * w;
    var base = (1 - streakAmp) + streakAmp * noise(i * 1.7 + 3);
    final edge = math.pow((t - 0.5).abs() * 2, 2.2).toDouble();
    base *= 1 + edgeInk * edge; // ink-darker long edges
    final p0 = start + n * off;
    final p1 = end + n * off;
    double la(double k) =>
        baseA * base * ((1 - lengthAmp) + lengthAmp * noise(i * 0.5 + k));
    paint
      ..strokeWidth = bandStep * 1.3 // overlap so there are no seams
      ..shader = ui.Gradient.linear(p0, p1, [
        withA(la(0)),
        withA(la(6)),
        withA(la(12)),
      ], const [0.0, 0.5, 1.0]);
    canvas.drawLine(p0, p1, paint);
  }
  paint.shader = null;

  // Frayed: dry split-fork streaks trailing off both ends.
  if (style.texture == HighlighterTexture.frayed) {
    final fn = _MarkerNoise(seed * 5 + 1);
    final fray = Paint()
      ..isAntiAlias = true
      ..strokeCap = StrokeCap.round;
    for (final (ex, sign) in [(end, 1.0), (start, -1.0)]) {
      for (var i = 0; i < 7; i++) {
        final off = (fn(i * 1.3) - 0.5) * w * 0.95;
        final length = 6 + fn(i * 2.1 + 9) * 26;
        final p0 = ex + n * off;
        final p1 =
            ex + u * (sign * length) + n * (off + (fn(i * 4.0) - 0.5) * 4);
        fray
          ..color = withA(baseA * (0.25 + 0.5 * fn(i * 0.7 + 3)))
          ..strokeWidth = 1.2 + fn(i.toDouble()) * 2.2;
        canvas.drawLine(p0, p1, fray);
      }
    }
  }
}

/// Paints the drawable list (annotation layer) and, if [selectedIndex] is set,
/// a selection rectangle + corner handles around that drawable.
///
/// [blurredFull]/[pixelatedFull] are the whole frame pre-blurred / pre-pixelated
/// once (computed when the tool is selected); the blur/pixelate regions just
/// clip them to the dragged rect — no per-frame recompute. Null on the vector-
/// only paths (unit tests), where those regions draw a neutral placeholder.
class DrawablePainter extends CustomPainter {
  final List<Drawable> drawables;
  final int? selectedIndex;
  final ui.Image? blurredFull;
  final ui.Image? pixelatedFull;
  const DrawablePainter({
    required this.drawables,
    required this.selectedIndex,
    this.blurredFull,
    this.pixelatedFull,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final d in drawables) {
      _paintOne(canvas, d, size);
    }
    final i = selectedIndex;
    if (i != null && i >= 0 && i < drawables.length) {
      _paintSelection(canvas, drawables[i]);
    }
  }

  void _paintOne(Canvas canvas, Drawable d, Size size) {
    switch (d) {
      case RectangleDrawable():
        final paint = Paint()
          ..color = d.style.color
          ..strokeWidth = d.style.strokeWidth
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round;
        // Rounded corners; radius eases down for small rectangles.
        final radius = (d.rect.shortestSide / 4).clamp(0.0, 12.0);
        canvas.drawRRect(
          RRect.fromRectAndRadius(d.rect, Radius.circular(radius)),
          paint,
        );
      case EllipseDrawable():
        final paint = Paint()
          ..color = d.style.color
          ..strokeWidth = d.style.strokeWidth
          ..style = PaintingStyle.stroke
          ..isAntiAlias = true;
        canvas.drawOval(d.rect, paint);
      case ArrowDrawable():
        _paintArrow(canvas, d.start, d.end, d.style.color, d.style.strokeWidth);
      case LineDrawable():
        final paint = Paint()
          ..color = d.style.color
          ..strokeWidth = d.style.strokeWidth
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true;
        canvas.drawLine(d.start, d.end, paint);
      case HighlighterDrawable():
        _paintHighlighter(canvas, d);
      case PenDrawable():
        _paintPen(canvas, d);
      case TextDrawable():
        final tp = TextPainter(
          text: buildTextSpan(d),
          textDirection: TextDirection.ltr,
          strutStyle: StrutStyle.disabled, // match the inline field's layout
        )..layout();
        tp.paint(canvas, d.position);
      case StepDrawable():
        _paintStep(canvas, d);
      case BlurDrawable():
        _paintMasked(canvas, d.rect, size, blurredFull, nearest: false);
      case PixelateDrawable():
        _paintMasked(canvas, d.rect, size, pixelatedFull, nearest: true);
      case ImageDrawable():
        canvas.drawImageRect(
          d.image,
          Rect.fromLTWH(
            0,
            0,
            d.image.width.toDouble(),
            d.image.height.toDouble(),
          ),
          d.rect,
          Paint()..filterQuality = FilterQuality.medium,
        );
    }
  }

  /// Clips the pre-computed whole-frame [full] image (blurred or pixelated) to
  /// [rect], stretched across the display ([size]) so it aligns 1:1 with the
  /// frozen frame beneath. [nearest] keeps pixelate blocks crisp. A neutral
  /// placeholder shows while [full] is still being computed (or in unit tests).
  void _paintMasked(
    Canvas canvas,
    Rect rect,
    Size size,
    ui.Image? full, {
    required bool nearest,
  }) {
    if (full == null) {
      canvas.drawRect(rect, Paint()..color = const Color(0x33000000));
      return;
    }
    canvas.save();
    canvas.clipRect(rect);
    canvas.drawImageRect(
      full,
      Rect.fromLTWH(0, 0, full.width.toDouble(), full.height.toDouble()),
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()
        ..filterQuality = nearest ? FilterQuality.none : FilterQuality.medium,
    );
    canvas.restore();
  }

  void _paintPen(Canvas canvas, PenDrawable d) {
    if (d.points.isEmpty) return;
    if (d.points.length == 1) {
      canvas.drawCircle(
        d.points.first,
        d.style.strokeWidth / 2,
        Paint()..color = d.style.color,
      );
      return;
    }
    final paint = Paint()
      ..color = d.style.color
      ..strokeWidth = d.style.strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    final path = Path()..moveTo(d.points.first.dx, d.points.first.dy);
    for (var i = 1; i < d.points.length; i++) {
      path.lineTo(d.points[i].dx, d.points[i].dy);
    }
    canvas.drawPath(path, paint);
  }

  void _paintHighlighter(Canvas canvas, HighlighterDrawable d) =>
      paintHighlighterStroke(canvas, d.points, d.style);

  void _paintStep(Canvas canvas, StepDrawable d) {
    canvas.drawCircle(
      d.center,
      d.radius,
      Paint()
        ..color = d.style.color
        ..isAntiAlias = true,
    );
    final tp = TextPainter(
      text: TextSpan(
        text: '${d.number}',
        style: TextStyle(
          color: const Color(0xFFFFFFFF),
          fontSize: d.radius * 1.2,
          height: 1,
          fontWeight: FontWeight.w700,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      Offset(d.center.dx - tp.width / 2, d.center.dy - tp.height / 2),
    );
  }

  /// Tapered, filled "brush" arrow: thin at the tail, swelling into a solid
  /// arrowhead — a marker-pen feel rather than a hairline.
  void _paintArrow(
    Canvas canvas,
    Offset start,
    Offset end,
    Color color,
    double w,
  ) {
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    final dir = end - start;
    final len = dir.distance;
    if (len < 1) {
      canvas.drawCircle(start, w / 2, fill);
      return;
    }
    final u = Offset(dir.dx / len, dir.dy / len);
    final n = Offset(-u.dy, u.dx); // unit normal
    final headLen = (w * 3.2).clamp(8.0, len);
    final headHalf = w * 1.6; // arrowhead half-width
    final shaftHalf = w * 0.7; // shaft half-width at the head base
    final tailHalf = w * 0.25; // thin tail
    final hb = end - u * headLen; // head base
    Offset at(Offset base, Offset normal, double s) =>
        Offset(base.dx + normal.dx * s, base.dy + normal.dy * s);
    final path = Path()
      ..moveTo(at(start, n, tailHalf).dx, at(start, n, tailHalf).dy)
      ..lineTo(at(hb, n, shaftHalf).dx, at(hb, n, shaftHalf).dy)
      ..lineTo(at(hb, n, headHalf).dx, at(hb, n, headHalf).dy)
      ..lineTo(end.dx, end.dy)
      ..lineTo(at(hb, n, -headHalf).dx, at(hb, n, -headHalf).dy)
      ..lineTo(at(hb, n, -shaftHalf).dx, at(hb, n, -shaftHalf).dy)
      ..lineTo(at(start, n, -tailHalf).dx, at(start, n, -tailHalf).dy)
      ..close();
    canvas.drawPath(path, fill);
  }

  void _paintSelection(Canvas canvas, Drawable d) {
    final r = d.bounds.inflate(4);
    final line = Paint()
      ..color = const Color(0xFF2196F3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(r, line);
    // Corner resize handles only for rect-defined shapes (rectangle/ellipse and
    // the raster regions); strokes/text are move-only, so handles would mislead.
    if (d is! RectShaped) return;
    final fill = Paint()..color = const Color(0xFF2196F3);
    final ring = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final c in [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight]) {
      canvas.drawCircle(c, 5.5, fill);
      canvas.drawCircle(c, 5.5, ring);
    }
  }

  @override
  bool shouldRepaint(DrawablePainter old) =>
      old.drawables != drawables ||
      old.selectedIndex != selectedIndex ||
      old.blurredFull != blurredFull ||
      old.pixelatedFull != pixelatedFull;
}
