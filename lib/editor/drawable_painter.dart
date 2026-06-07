import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../overlay/hud_lines.dart';
import 'curve.dart';
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

/// Paints a highlighter band along the Catmull-Rom curve through [control]
/// (control points; first/last = the ends). Translucent srcOver only (no
/// multiply — it vanishes on dark screenshots); honours the colour's own alpha.
/// The Clean texture also honours [DrawStyle.lineStyle]; streaks/frayed are
/// textured and ignore it. Reused by the toolbar's texture preview (a 2-point
/// list = a straight band).
void paintHighlighterStroke(
  Canvas canvas,
  List<Offset> control,
  DrawStyle style,
) {
  if (control.isEmpty) return;
  final w = style.strokeWidth * 5; // wide marker band
  final color = style.color;
  final spine = sampleCatmullRom(control);
  final start = spine.first;
  final end = spine.last;
  var total = 0.0;
  for (var i = 1; i < spine.length; i++) {
    total += (spine[i] - spine[i - 1]).distance;
  }
  if (total < 0.5) {
    canvas.drawCircle(
      start,
      w / 2,
      Paint()
        ..color = color
        ..isAntiAlias = true,
    );
    return;
  }
  final path = catmullRomPath(control);

  // Clean: a plain round-capped translucent band along the curve. The highlighter
  // is a marker — it does NOT take line styles (dashing reads inconsistently
  // across its textures), so this is always a solid band.
  if (style.texture == HighlighterTexture.clean) {
    final band = Paint()
      ..color = color
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;
    canvas.drawPath(path, band);
    return;
  }

  // ---- tunable constants (iterate in-app) --------------------------------
  const streakCount = 18; // felt-tip streak lines across the band — a COUNT, so
  // the look scales with width AND stays cheap (≈this many draws per stroke).
  const streakAmp = 0.4; // per-streak intensity variation
  const lengthAmp = 0.22; // along-stroke variation (per-streak gradient)
  const edgeInk = 0.7; // extra darkening at the long edges

  final seed =
      (start.dx * 131 + start.dy * 557 + end.dx * 1289 + end.dy * 2741).round();
  final noise = _MarkerNoise(seed);
  final baseA = color.a; // the chosen alpha (0..1)
  Color withA(double a) => color.withValues(alpha: a.clamp(0.0, 0.95));

  // Unit normal at each spine vertex so the streaks run PARALLEL to the curve.
  final normals = <Offset>[];
  for (var j = 0; j < spine.length; j++) {
    final a = spine[j == 0 ? 0 : j - 1];
    final b = spine[j == spine.length - 1 ? j : j + 1];
    var t = b - a;
    final l = t.distance;
    t = l == 0 ? const Offset(1, 0) : t / l;
    normals.add(Offset(-t.dy, t.dx));
  }

  // A FEW long streaks offset across the band (≈streakCount draws), each a
  // polyline following the curve at its own offset + intensity (3-stop gradient
  // along it for felt-tip lengthwise variation).
  final paint = Paint()
    ..isAntiAlias = true
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.butt;
  final bandStep = w / streakCount;
  for (var i = 0; i < streakCount; i++) {
    final tt = (i + 0.5) / streakCount; // 0..1 across the band
    final off = (tt - 0.5) * w;
    var base = (1 - streakAmp) + streakAmp * noise(i * 1.7 + 3);
    final edge = math.pow((tt - 0.5).abs() * 2, 2.2).toDouble();
    base *= 1 + edgeInk * edge; // ink-darker long edges
    double la(double k) =>
        baseA * base * ((1 - lengthAmp) + lengthAmp * noise(i * 0.5 + k));
    final streak = Path();
    final s0 = spine.first + normals.first * off;
    streak.moveTo(s0.dx, s0.dy);
    for (var j = 1; j < spine.length; j++) {
      final sj = spine[j] + normals[j] * off;
      streak.lineTo(sj.dx, sj.dy);
    }
    final s1 = spine.last + normals.last * off;
    paint
      ..strokeWidth = bandStep * 1.3 // overlap so there are no seams
      ..shader = ui.Gradient.linear(s0, s1, [
        withA(la(0)),
        withA(la(6)),
        withA(la(12)),
      ], const [0.0, 0.5, 1.0]);
    canvas.drawPath(streak, paint);
  }
  paint.shader = null;

  // Frayed: dry split-fork streaks off both ends, along the end tangents.
  if (style.texture == HighlighterTexture.frayed) {
    final fn = _MarkerNoise(seed * 5 + 1);
    final fray = Paint()
      ..isAntiAlias = true
      ..strokeCap = StrokeCap.round;
    final ends = [
      (end, curveTangent(control, atEnd: true), normals.last),
      (start, curveTangent(control, atEnd: false), normals.first),
    ];
    for (final (ex, u, nrm) in ends) {
      for (var i = 0; i < 7; i++) {
        final off = (fn(i * 1.3) - 0.5) * w * 0.95;
        final length = 6 + fn(i * 2.1 + 9) * 26;
        final p0 = ex + nrm * off;
        final p1 = ex + u * length + nrm * (off + (fn(i * 4.0) - 0.5) * 4);
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
  final ui.Image? blurredFull;
  final ui.Image? pixelatedFull;
  const DrawablePainter({
    required this.drawables,
    this.blurredFull,
    this.pixelatedFull,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final d in drawables) {
      _paintOne(canvas, d, size);
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
        _paintArrow(canvas, d);
      case LineDrawable():
        final paint = Paint()
          ..color = d.style.color
          ..strokeWidth = d.style.strokeWidth
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..isAntiAlias = true;
        final path = catmullRomPath(d.points);
        _withShadow(canvas, d.style, paint,
            (c, p) => drawStyledPath(c, path, p, d.style.lineStyle, d.style.strokeWidth));
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

  /// Arrow: a (possibly curved, possibly dashed) shaft + a long pointed barbed
  /// head at the end and/or start per [DrawStyle.arrowHeads], each oriented by the
  /// curve's tangent there. The shaft is trimmed back at each headed end so it
  /// doesn't poke through the head's concave back. Shaft + heads share one shadow.
  void _paintArrow(Canvas canvas, ArrowDrawable d) {
    final style = d.style;
    final w = style.strokeWidth;
    final pts = d.points;
    if (pts.length < 2 || (pts.last - pts.first).distance < 1) {
      final dot = Paint()
        ..color = style.color
        ..isAntiAlias = true;
      _withShadow(canvas, style, dot, (c, p) => c.drawCircle(pts.first, w / 2, p));
      return;
    }
    final heads = style.arrowHeads;
    final atEnd = heads == ArrowHeads.end || heads == ArrowHeads.both;
    final atStart = heads == ArrowHeads.start || heads == ArrowHeads.both;
    final headLen = w * 4.9; // tip -> barb line (long/pointed)
    final back = headLen * 0.15; // shallow concave back
    final trim = headLen - back; // shaft is cut to the head's notch
    final full = catmullRomPath(pts);
    final shaft = _trimContour(full, atStart ? trim : 0, atEnd ? trim : 0);
    final shaftPaint = Paint()
      ..color = style.color
      ..strokeWidth = w
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    _withShadow(canvas, style, shaftPaint, (c, p) {
      drawStyledPath(c, shaft, p, style.lineStyle, w);
      final headFill = Paint()
        ..color = p.color
        ..style = PaintingStyle.fill
        ..maskFilter = p.maskFilter // carry the shadow blur on the shadow pass
        ..isAntiAlias = true;
      if (atEnd) _drawArrowHead(c, pts, atEnd: true, w: w, fill: headFill);
      if (atStart) _drawArrowHead(c, pts, atEnd: false, w: w, fill: headFill);
    });
  }

  /// A single barbed arrowhead at the curve's [atEnd] (or start) tip, pointing
  /// outward along the tangent there.
  void _drawArrowHead(
    Canvas canvas,
    List<Offset> pts, {
    required bool atEnd,
    required double w,
    required Paint fill,
  }) {
    final tip = atEnd ? pts.last : pts.first;
    final u = curveTangent(pts, atEnd: atEnd); // unit outward
    final n = Offset(-u.dy, u.dx);
    final headHalf = w * 1.6;
    final headLen = w * 4.9;
    final back = headLen * 0.15;
    final barbR = tip - u * headLen + n * headHalf;
    final barbL = tip - u * headLen - n * headHalf;
    final j = tip - u * (headLen - back); // concave notch
    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(barbR.dx, barbR.dy)
      ..lineTo(j.dx, j.dy)
      ..lineTo(barbL.dx, barbL.dy)
      ..close();
    canvas.drawPath(path, fill);
  }

  /// Extract the single contour of [path] trimmed by [fromStart]/[fromEnd] arc
  /// length (a line/arrow spline is one contour). Empty if fully trimmed.
  Path _trimContour(Path path, double fromStart, double fromEnd) {
    final metrics = path.computeMetrics().toList();
    if (metrics.isEmpty) return Path();
    final m = metrics.first;
    final a = fromStart.clamp(0.0, m.length).toDouble();
    final b = (m.length - fromEnd).clamp(a, m.length).toDouble();
    if (b <= a) return Path();
    return m.extractPath(a, b);
  }

  @override
  bool shouldRepaint(DrawablePainter old) =>
      old.drawables != drawables ||
      old.blurredFull != blurredFull ||
      old.pixelatedFull != pixelatedFull;
}

/// The selected drawable's highlight: a flowing two-tone marching-ants outline
/// (matching the crop / crosshair / window-snap HUD) plus monochrome resize /
/// endpoint handles. Kept in its OWN painter (not [DrawablePainter]) so it can
/// animate via [march] without re-rasterizing the whole annotation layer each
/// frame. [selected] is the currently selected (or mid-edit) drawable, or null.
class SelectionHighlightPainter extends CustomPainter {
  final Drawable? selected;
  final ValueListenable<double>? march;
  const SelectionHighlightPainter({required this.selected, this.march})
    : super(repaint: march);

  @override
  void paint(Canvas canvas, Size size) {
    final d = selected;
    if (d == null) return;
    final phase = (march?.value ?? 0) * kHudDashPeriod;
    // Box flush to the shape's geometric bounds (no outward inflation), so the
    // outline sits right on the shape's baseline.
    final r = d.bounds;
    drawMarchingPolyline(
      canvas,
      [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft],
      phase: phase,
    );
    // Segment shapes (line/arrow/highlighter): the box PLUS a handle at every
    // control point (endpoints + interior curve points), so each is grabbable
    // and the span is easy to spot.
    if (d is Segmented) {
      _paintHandleDots(canvas, (d as Segmented).points);
      return;
    }
    // Corner resize handles only for rect-defined shapes (rectangle/ellipse and
    // the raster regions); pen/text/step are move-only, so handles would mislead.
    if (d is! RectShaped) return;
    paintResizeHandles(canvas, r);
  }

  @override
  bool shouldRepaint(SelectionHighlightPainter old) =>
      old.selected != selected || old.march != march;
}

/// The shared corner-handle style — a monochrome dot (white fill + dark ring, so
/// it reads on any background, matching the two-tone HUD) at each corner of [r].
/// Used by the drawable selection AND the editor crop selection so resize handles
/// look identical everywhere.
void paintResizeHandles(Canvas canvas, Rect r) =>
    _paintHandleDots(canvas, [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight]);

/// Draws a handle (white filled circle + dark ring) at each point. Shared by the
/// rect corner handles and the segment endpoint handles so they look identical.
void _paintHandleDots(Canvas canvas, List<Offset> points) {
  final fill = Paint()..color = const Color(0xFFFFFFFF);
  final ring = Paint()
    ..color = const Color(0xFF000000)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5;
  for (final c in points) {
    canvas.drawCircle(c, 5.5, fill);
    canvas.drawCircle(c, 5.5, ring);
  }
}
