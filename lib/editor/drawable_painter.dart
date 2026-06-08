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
// The text drop shadow, cast by whichever layer is outermost (pill > outline >
// glyphs) so it never floats oddly between layers.
const List<Shadow> _kTextShadow = [
  Shadow(
    color: _kShadowColor,
    offset: _kShadowOffset,
    blurRadius: _kShadowTextBlur,
  ),
];

// ---- arrowhead geometry (DrawStyle.arrowHeadScale) ---------------------------
// Head dimensions in stroke widths; multiplied by arrowHeadScale (default 1.0 =
// the legacy size). Shared by _paintArrow (shaft trim) and _drawArrowHead so the
// trim and the head always agree.
const double _kArrowHeadLenRatio = 4.9; // tip -> barb line
const double _kArrowHeadHalfRatio = 1.6; // barb half-width
const double _kArrowHeadBackRatio = 0.15; // concave back, in head lengths

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

/// Draws a rect/ellipse shape as shadow -> fill -> stroke (z-order), so a drop
/// shadow never haloes over the fill and the fill sits beneath the outline. With
/// a transparent fill and shadow off this draws only the stroke geom — byte for
/// byte the legacy single-stroke paint, keeping the default export identical.
void _paintFilledShape(
  Canvas canvas,
  DrawStyle style,
  void Function(Canvas, Paint) geom,
) {
  final hasFill = style.fillColor.a > 0;
  if (style.shadow) {
    final sp = Paint()
      ..style = hasFill ? PaintingStyle.fill : PaintingStyle.stroke
      ..strokeWidth = style.strokeWidth
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true
      ..color = _kShadowColor
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, _kShadowSigma);
    canvas.save();
    canvas.translate(_kShadowOffset.dx, _kShadowOffset.dy);
    geom(canvas, sp);
    canvas.restore();
  }
  if (hasFill) {
    geom(
      canvas,
      Paint()
        ..color = style.fillColor
        ..style = PaintingStyle.fill
        ..isAntiAlias = true,
    );
  }
  geom(
    canvas,
    Paint()
      ..color = style.color
      ..strokeWidth = style.strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true,
  );
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
/// Looks up the cached region-local effect image for a blur/pixelate drawable, or
/// null while it is being drawn / computed (then a styled placeholder is drawn).
/// Supplied by EditorCore (live editor) and composite (export).
typedef EffectImageLookup = ui.Image? Function(Drawable d);

/// [effectImage] returns the per-region pre-rasterised blur/pixelate image (region
/// rect 1:1) for a settled region, or null while it is being drawn / computed (a
/// styled placeholder is drawn instead). A null lookup on the vector-only paths
/// (unit tests) -> every region shows the placeholder.
class DrawablePainter extends CustomPainter {
  final List<Drawable> drawables;
  final EffectImageLookup? effectImage;
  const DrawablePainter({required this.drawables, this.effectImage});

  @override
  void paint(Canvas canvas, Size size) {
    for (final d in drawables) {
      _paintOne(canvas, d, size);
    }
  }

  void _paintOne(Canvas canvas, Drawable d, Size size) {
    switch (d) {
      case RectangleDrawable():
        // Auto radius (eases down for small rects) unless overridden; resolved by
        // the shared pure helper so the painter and tests agree.
        final radius = resolveCornerRadius(d.style.cornerRadius, d.rect);
        final rrect = RRect.fromRectAndRadius(d.rect, Radius.circular(radius));
        _paintFilledShape(canvas, d.style, (c, p) => c.drawRRect(rrect, p));
      case EllipseDrawable():
        _paintFilledShape(canvas, d.style, (c, p) => c.drawOval(d.rect, p));
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
        final hasFill = d.style.fillColor.a > 0;
        final hasOutline = d.style.outlineColor.a > 0;
        // The drop shadow is cast by the OUTERMOST visible layer: the pill if there
        // is a background, else the outline ring, else the glyphs. (The shadow is
        // injected only at paint time — never in textStyleOf, which the transparent
        // inline editing field shares and would float a shadow under empty glyphs.)
        final glyphShadow = d.style.shadow && !hasFill && !hasOutline;
        final span = glyphShadow
            ? TextSpan(
                text: d.text.isEmpty ? ' ' : d.text,
                style: textStyleOf(d.style).copyWith(shadows: _kTextShadow),
              )
            : buildTextSpan(d);
        final tp = TextPainter(
          text: span,
          textDirection: TextDirection.ltr,
          strutStyle: StrutStyle.disabled, // match the inline field's layout
        )..layout();
        // Background pill behind the text (A1). Default transparent fill -> skipped
        // -> byte-identical. The text stays at d.position; the pill draws around it.
        // When shadow is on, the pill casts it (a blurred, offset rrect).
        if (hasFill) {
          final bg = textBackgroundRect(d.position & tp.size, d.style.fontSize);
          final rrect = RRect.fromRectAndRadius(
            bg,
            Radius.circular(textBackgroundRadius(bg, d.style.fontSize)),
          );
          if (d.style.shadow) {
            canvas.save();
            canvas.translate(_kShadowOffset.dx, _kShadowOffset.dy);
            canvas.drawRRect(
              rrect,
              Paint()
                ..color = _kShadowColor
                ..maskFilter =
                    const MaskFilter.blur(BlurStyle.normal, _kShadowSigma),
            );
            canvas.restore();
          }
          canvas.drawRRect(
            rrect,
            Paint()
              ..color = d.style.fillColor
              ..isAntiAlias = true,
          );
        }
        // Glyph outline under the fill text (A1). A stroke foreground pass — built
        // WITHOUT a color (Flutter forbids color + foreground together).
        if (hasOutline) {
          // Repaints the glyph run with [fg] as a stroke foreground at d.position.
          void paintOutline(Paint fg) {
            TextPainter(
              text: TextSpan(
                text: d.text.isEmpty ? ' ' : d.text,
                style: TextStyle(
                  fontSize: d.style.fontSize,
                  height: kTextLineHeight,
                  fontFamily: d.style.fontFamily,
                  foreground: fg,
                ),
              ),
              textDirection: TextDirection.ltr,
              strutStyle: StrutStyle.disabled,
            )..layout()
              ..paint(canvas, d.position);
          }

          final w = textOutlineWidth(d.style.fontSize);
          // The outline casts the drop shadow when no pill does. A TextStyle.shadows
          // on a stroke run renders as the narrower glyph FILL (hidden behind the
          // wider outline), so paint an explicit stroke-shaped shadow instead — its
          // outer edge matches the outline silhouette.
          if (d.style.shadow && !hasFill) {
            canvas.save();
            canvas.translate(_kShadowOffset.dx, _kShadowOffset.dy);
            paintOutline(
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = w
                ..strokeJoin = StrokeJoin.round
                ..color = _kShadowColor
                ..maskFilter =
                    const MaskFilter.blur(BlurStyle.normal, _kShadowSigma)
                ..isAntiAlias = true,
            );
            canvas.restore();
          }
          paintOutline(
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = w
              ..strokeJoin = StrokeJoin.round
              ..color = d.style.outlineColor
              ..isAntiAlias = true,
          );
        }
        tp.paint(canvas, d.position);
      case StepDrawable():
        _paintStep(canvas, d);
      case BlurDrawable():
        _paintEffect(canvas, d, d.rect, isBlur: true);
      case PixelateDrawable():
        _paintEffect(canvas, d, d.rect, isBlur: false);
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

  /// Draws a blur/pixelate region: its pre-rasterised region image (stretched 1:1
  /// over the rect; nearest-neighbour for pixelate -> crisp blocks), or a styled
  /// placeholder while the image is unavailable (being drawn / still computing).
  void _paintEffect(Canvas canvas, Drawable d, Rect rect, {required bool isBlur}) {
    final img = effectImage?.call(d);
    if (img == null) {
      _paintEffectPlaceholder(
        canvas,
        rect,
        isBlur: isBlur,
        strength: d.style.strength,
      );
      return;
    }
    canvas.save();
    canvas.clipRect(rect);
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      rect,
      Paint()..filterQuality = isBlur ? FilterQuality.medium : FilterQuality.none,
    );
    canvas.restore();
  }

  /// The Glimpr-styled "effect pending here" placeholder, shown while a region is
  /// being drawn/moved/resized or its effect image is still computing: a frosted
  /// dark scrim + a faint centred effect-icon watermark + a static two-tone dashed
  /// border (HUD identity) + a corner glass pill naming the effect and strength.
  void _paintEffectPlaceholder(
    Canvas canvas,
    Rect rect, {
    required bool isBlur,
    required double strength,
  }) {
    canvas.save();
    canvas.clipRect(rect);
    // Frosted dark scrim (Aurora navy) — reads as a glass panel over the content.
    canvas.drawRect(rect, Paint()..color = const Color(0xCC0F1526));
    // Faint centred effect-icon watermark.
    final icon = isBlur ? Icons.blur_on : Icons.grid_on;
    final iconSize = (rect.shortestSide * 0.4).clamp(0.0, 56.0);
    if (iconSize >= 16) {
      final ip = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(icon.codePoint),
          style: TextStyle(
            fontFamily: icon.fontFamily,
            package: icon.fontPackage,
            fontSize: iconSize,
            color: const Color(0x30FFFFFF),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      ip.paint(canvas, rect.center - Offset(ip.width / 2, ip.height / 2));
    }
    canvas.restore();
    // Static two-tone dashed border (HUD identity; phase 0 = not animated, so the
    // annotation layer is not re-rasterised every march tick).
    drawMarchingPolyline(
      canvas,
      [rect.topLeft, rect.topRight, rect.bottomRight, rect.bottomLeft],
      phase: 0,
    );
    // Corner glass pill: "[Blur|Pixelate] N", drawn when it fits the region.
    final label = '${isBlur ? 'Blur' : 'Pixelate'} ${strength.round()}';
    final lp = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(
          color: Color(0xFFFFFFFF),
          fontSize: 11,
          height: 1.2,
          fontWeight: FontWeight.w600,
          decoration: TextDecoration.none,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final pillW = lp.width + 16, pillH = lp.height + 8;
    if (rect.width >= pillW + 8 && rect.height >= pillH + 8) {
      final pill = Rect.fromLTWH(rect.left + 6, rect.top + 6, pillW, pillH);
      final rr = RRect.fromRectAndRadius(pill, const Radius.circular(8));
      canvas.drawRRect(rr, Paint()..color = const Color(0xF2202020));
      canvas.drawRRect(
        rr,
        Paint()
          ..color = const Color(0x55FFFFFF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
      lp.paint(canvas, Offset(pill.left + 8, pill.top + 4));
    }
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
    // Freehand strokes are decimated on release (editor_core), so the stored
    // points are already simplified; draw them as a smooth Catmull-Rom spline.
    final path = catmullRomPath(d.points);
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
    final scale = style.arrowHeadScale;
    final headLen = w * _kArrowHeadLenRatio * scale; // tip -> barb line
    final back = headLen * _kArrowHeadBackRatio; // shallow concave back
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
      if (atEnd) {
        _drawArrowHead(c, pts, atEnd: true, w: w, scale: scale, fill: headFill);
      }
      if (atStart) {
        _drawArrowHead(c, pts, atEnd: false, w: w, scale: scale, fill: headFill);
      }
    });
  }

  /// A single barbed arrowhead at the curve's [atEnd] (or start) tip, pointing
  /// outward along the tangent there.
  void _drawArrowHead(
    Canvas canvas,
    List<Offset> pts, {
    required bool atEnd,
    required double w,
    required double scale,
    required Paint fill,
  }) {
    final tip = atEnd ? pts.last : pts.first;
    final u = curveTangent(pts, atEnd: atEnd); // unit outward
    final n = Offset(-u.dy, u.dx);
    final headHalf = w * _kArrowHeadHalfRatio * scale;
    final headLen = w * _kArrowHeadLenRatio * scale;
    final back = headLen * _kArrowHeadBackRatio;
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
      old.drawables != drawables || old.effectImage != effectImage;
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

/// The shared resize-handle style — a monochrome dot (white fill + dark ring, so
/// it reads on any background, matching the two-tone HUD) at each of [r]'s 8
/// handles: the 4 corners (scale both axes) plus the 4 edge midpoints (scale a
/// single axis). Used by the drawable selection AND the editor crop selection so
/// resize handles look identical everywhere.
void paintResizeHandles(Canvas canvas, Rect r) => _paintHandleDots(canvas, [
      r.topLeft,
      r.topRight,
      r.bottomLeft,
      r.bottomRight,
      Offset(r.center.dx, r.top),
      Offset(r.center.dx, r.bottom),
      Offset(r.left, r.center.dy),
      Offset(r.right, r.center.dy),
    ]);

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
