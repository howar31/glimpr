import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'drawable.dart';
import 'text_metrics.dart';

/// Paints the drawable list (annotation layer) and, if [selectedIndex] is set,
/// a selection rectangle + corner handles around that drawable.
///
/// [frozenImage] (native pixels) + [scaleFactor] let the raster regions
/// (blur/pixelate) re-sample the underlying screenshot; null on the vector-only
/// paths (unit tests), where those regions fall back to a neutral placeholder.
class DrawablePainter extends CustomPainter {
  final List<Drawable> drawables;
  final int? selectedIndex;
  final ui.Image? frozenImage;
  final double scaleFactor;
  const DrawablePainter({
    required this.drawables,
    required this.selectedIndex,
    this.frozenImage,
    this.scaleFactor = 1,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final d in drawables) {
      _paintOne(canvas, d);
    }
    final i = selectedIndex;
    if (i != null && i >= 0 && i < drawables.length) {
      _paintSelection(canvas, drawables[i]);
    }
  }

  void _paintOne(Canvas canvas, Drawable d) {
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
            RRect.fromRectAndRadius(d.rect, Radius.circular(radius)), paint);
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
        )..layout();
        tp.paint(canvas, d.position);
      case StepDrawable():
        _paintStep(canvas, d);
      case BlurDrawable():
        _paintBlur(canvas, d.rect, d.sigma);
      case PixelateDrawable():
        _paintPixelate(canvas, d);
      case ImageDrawable():
        canvas.drawImageRect(
          d.image,
          Rect.fromLTWH(
              0, 0, d.image.width.toDouble(), d.image.height.toDouble()),
          d.rect,
          Paint()..filterQuality = FilterQuality.medium,
        );
    }
  }

  /// Draws the frozen pixels under [rect] blurred (live re-sample). Clipped so
  /// the blur cannot bleed past the region. Placeholder when no source image.
  void _paintBlur(Canvas canvas, Rect rect, double sigma) {
    final frozen = frozenImage;
    if (frozen == null) {
      canvas.drawRect(rect, Paint()..color = const Color(0x33000000));
      return;
    }
    final src = Rect.fromLTRB(rect.left * scaleFactor, rect.top * scaleFactor,
        rect.right * scaleFactor, rect.bottom * scaleFactor);
    canvas.save();
    canvas.clipRect(rect);
    canvas.drawImageRect(
      frozen,
      src,
      rect,
      Paint()
        ..imageFilter = ui.ImageFilter.blur(
            sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.decal)
        ..filterQuality = FilterQuality.medium,
    );
    canvas.restore();
  }

  void _paintPixelate(Canvas canvas, PixelateDrawable d) {
    final mosaic = d.mosaic;
    if (mosaic != null) {
      // Upscale the tiny averaged image blocky (no smoothing) = mosaic look.
      canvas.drawImageRect(
        mosaic,
        Rect.fromLTWH(0, 0, mosaic.width.toDouble(), mosaic.height.toDouble()),
        d.rect,
        Paint()..filterQuality = FilterQuality.none,
      );
      return;
    }
    // Mosaic still computing -> live blur so raw pixels are never exposed.
    _paintBlur(canvas, d.rect, 8);
  }

  void _paintPen(Canvas canvas, PenDrawable d) {
    if (d.points.isEmpty) return;
    if (d.points.length == 1) {
      canvas.drawCircle(d.points.first, d.style.strokeWidth / 2,
          Paint()..color = d.style.color);
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
        d.center, d.radius, Paint()..color = d.style.color..isAntiAlias = true);
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
    tp.paint(canvas,
        Offset(d.center.dx - tp.width / 2, d.center.dy - tp.height / 2));
  }

  /// Tapered, filled "brush" arrow: thin at the tail, swelling into a solid
  /// arrowhead — a marker-pen feel rather than a hairline.
  void _paintArrow(
      Canvas canvas, Offset start, Offset end, Color color, double w) {
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
      old.frozenImage != frozenImage ||
      old.scaleFactor != scaleFactor;
}
