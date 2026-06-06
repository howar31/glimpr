import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'draw_style.dart';
import 'drawable.dart';
import 'text_metrics.dart';

// ---- drop-shadow tunables (DrawStyle.shadow) ---------------------------------
// Matches the design reference CSS drop-shadow(2px 2px 2px rgba(0,0,0,.75)): a
// tight, soft shadow. Shapes use a MaskFilter blur; text uses a ui.Shadow.
const Color _kShadowColor = Color(0xBF000000); // 75% black
const Offset _kShadowOffset = Offset(2, 2);
const double _kShadowSigma = 1.0; // shape MaskFilter blur stddev (~CSS 2px blur)
const double _kShadowTextBlur = 2.0; // text Shadow.blurRadius (CSS-style radius)

/// Draws [geom] as a blurred, offset drop shadow beneath the real shape when
/// [style.shadow] is on, then draws the real shape via the same closure. The
/// shadow paint copies [base]'s stroke/fill geometry so caps/joins/width match.
void _withShadow(
  Canvas canvas,
  DrawStyle style,
  Paint base,
  void Function(Canvas, Paint) geom,
) {
  if (style.shadow) {
    final sp = Paint()
      ..style = base.style
      ..strokeWidth = base.strokeWidth
      ..strokeCap = base.strokeCap
      ..strokeJoin = base.strokeJoin
      ..isAntiAlias = true
      ..color = _kShadowColor
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, _kShadowSigma);
    canvas.save();
    canvas.translate(_kShadowOffset.dx, _kShadowOffset.dy);
    geom(canvas, sp);
    canvas.restore();
  }
  geom(canvas, base);
}

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
        final rrect = RRect.fromRectAndRadius(d.rect, Radius.circular(radius));
        _withShadow(canvas, d.style, paint, (c, p) => c.drawRRect(rrect, p));
      case EllipseDrawable():
        final paint = Paint()
          ..color = d.style.color
          ..strokeWidth = d.style.strokeWidth
          ..style = PaintingStyle.stroke
          ..isAntiAlias = true;
        _withShadow(canvas, d.style, paint, (c, p) => c.drawOval(d.rect, p));
      case ArrowDrawable():
        _paintArrow(canvas, d.start, d.end, d.style);
      case LineDrawable():
        final paint = Paint()
          ..color = d.style.color
          ..strokeWidth = d.style.strokeWidth
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true;
        _withShadow(canvas, d.style, paint, (c, p) => c.drawLine(d.start, d.end, p));
      case HighlighterDrawable():
        _paintHighlighter(canvas, d);
      case PenDrawable():
        _paintPen(canvas, d);
      case TextDrawable():
        // The shadow is injected only at paint time — NOT in textStyleOf, which
        // the transparent inline editing field shares (it would float a shadow
        // under invisible glyphs while typing).
        final span = d.style.shadow
            ? TextSpan(
                text: d.text.isEmpty ? ' ' : d.text,
                style: textStyleOf(d.style).copyWith(
                  shadows: const [
                    Shadow(
                      color: _kShadowColor,
                      offset: _kShadowOffset,
                      blurRadius: _kShadowTextBlur,
                    ),
                  ],
                ),
              )
            : buildTextSpan(d);
        final tp = TextPainter(
          text: span,
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
      final dot = Paint()
        ..color = d.style.color
        ..isAntiAlias = true;
      _withShadow(
        canvas,
        d.style,
        dot,
        (c, p) => c.drawCircle(d.points.first, d.style.strokeWidth / 2, p),
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
    _withShadow(canvas, d.style, paint, (c, p) => c.drawPath(path, p));
  }

  void _paintHighlighter(Canvas canvas, HighlighterDrawable d) =>
      paintHighlighterStroke(canvas, d.points, d.style);

  void _paintStep(Canvas canvas, StepDrawable d) {
    final circle = Paint()
      ..color = d.style.color
      ..isAntiAlias = true;
    // The badge casts one shadow as a whole; the number rides on top, no shadow.
    _withShadow(
      canvas,
      d.style,
      circle,
      (c, p) => c.drawCircle(d.center, d.radius, p),
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

  /// Classic barbed arrow: a uniform thin shaft and a long, pointed head whose
  /// back edge cuts inward (the barbs sweep back slightly past where the shaft
  /// joins). One filled polygon, so it casts a single drop shadow. The multipliers
  /// below are the tunables for in-app polish.
  void _paintArrow(Canvas canvas, Offset start, Offset end, DrawStyle style) {
    final w = style.strokeWidth;
    final fill = Paint()
      ..color = style.color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    final dir = end - start;
    final len = dir.distance;
    if (len < 1) {
      _withShadow(canvas, style, fill, (c, p) => c.drawCircle(start, w / 2, p));
      return;
    }
    final u = Offset(dir.dx / len, dir.dy / len);
    final n = Offset(-u.dy, u.dx); // unit normal
    // ---- tunables (iterate in-app) ----
    final headHalf = w * 1.6; // head half-width at the barbs (~3.2x the shaft)
    final headLen = (w * 4.9).clamp(headHalf, len); // tip -> barb line (long/pointed)
    final shaftHalf = w / 2; // uniform shaft (= the stroke width)
    final back = headLen * 0.15; // shallow barb sweep -> concave back
    final barbR = end - u * headLen + n * headHalf;
    final barbL = end - u * headLen - n * headHalf;
    final j = end - u * (headLen - back); // shaft <-> head junction (concave notch)
    Offset at(Offset b, double s) => Offset(b.dx + n.dx * s, b.dy + n.dy * s);
    final path = Path()
      ..moveTo(at(start, shaftHalf).dx, at(start, shaftHalf).dy)
      ..lineTo(at(j, shaftHalf).dx, at(j, shaftHalf).dy)
      ..lineTo(barbR.dx, barbR.dy)
      ..lineTo(end.dx, end.dy)
      ..lineTo(barbL.dx, barbL.dy)
      ..lineTo(at(j, -shaftHalf).dx, at(j, -shaftHalf).dy)
      ..lineTo(at(start, -shaftHalf).dx, at(start, -shaftHalf).dy)
      ..close();
    _withShadow(canvas, style, fill, (c, p) => c.drawPath(path, p));
  }

  void _paintSelection(Canvas canvas, Drawable d) {
    // Segment shapes (line/arrow/highlighter) show two endpoint handles at the
    // start/end points — not a bounding box — so each end can be dragged.
    if (d is Segmented) {
      final seg = d as Segmented;
      _paintHandleDots(canvas, [seg.start, seg.end]);
      return;
    }
    final r = d.bounds.inflate(4);
    final line = Paint()
      ..color = const Color(0xFF2196F3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(r, line);
    // Corner resize handles only for rect-defined shapes (rectangle/ellipse and
    // the raster regions); pen/text/step are move-only, so handles would mislead.
    if (d is! RectShaped) return;
    paintResizeHandles(canvas, r);
  }

  @override
  bool shouldRepaint(DrawablePainter old) =>
      old.drawables != drawables ||
      old.selectedIndex != selectedIndex ||
      old.blurredFull != blurredFull ||
      old.pixelatedFull != pixelatedFull;
}

/// The shared corner-handle style — blue filled circle + white ring at each
/// corner of [r]. Used by the drawable selection AND the editor crop selection
/// so resize handles look identical everywhere.
void paintResizeHandles(Canvas canvas, Rect r) =>
    _paintHandleDots(canvas, [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight]);

/// Draws a handle (blue filled circle + white ring) at each point. Shared by the
/// rect corner handles and the segment endpoint handles so they look identical.
void _paintHandleDots(Canvas canvas, List<Offset> points) {
  final fill = Paint()..color = const Color(0xFF2196F3);
  final ring = Paint()
    ..color = const Color(0xFFFFFFFF)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5;
  for (final c in points) {
    canvas.drawCircle(c, 5.5, fill);
    canvas.drawCircle(c, 5.5, ring);
  }
}
