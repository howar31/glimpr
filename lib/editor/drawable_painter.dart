import 'package:flutter/material.dart';
import 'drawable.dart';
import 'text_metrics.dart';

/// Paints the drawable list (annotation layer) and, if [selectedIndex] is set,
/// a selection rectangle + corner handles around that drawable.
class DrawablePainter extends CustomPainter {
  final List<Drawable> drawables;
  final int? selectedIndex;
  const DrawablePainter({required this.drawables, required this.selectedIndex});

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
      case ArrowDrawable():
        _paintArrow(canvas, d.start, d.end, d.style.color, d.style.strokeWidth);
      case TextDrawable():
        final tp = TextPainter(
          text: buildTextSpan(d),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, d.position);
    }
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
    // Corner resize handles only for rectangles (text/arrow are move-only, so
    // handles there would be misleading).
    if (d is! RectangleDrawable) return;
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
      old.drawables != drawables || old.selectedIndex != selectedIndex;
}
