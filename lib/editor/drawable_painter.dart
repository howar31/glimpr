import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'drawable.dart';
import 'text_metrics.dart';

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
        // Wide, translucent marker band. One stroked path = uniform opacity (no
        // self-overlap darkening along the band).
        final paint = Paint()
          ..color = d.style.color.withValues(alpha: 0.38)
          ..strokeWidth = d.style.strokeWidth * 5
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true;
        canvas.drawLine(d.start, d.end, paint);
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
