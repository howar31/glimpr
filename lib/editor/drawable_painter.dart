import 'package:flutter/material.dart';
import 'drawable.dart';

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
      _paintSelection(canvas, drawables[i].bounds);
    }
  }

  void _paintOne(Canvas canvas, Drawable d) {
    final paint = Paint()
      ..color = d.style.color
      ..strokeWidth = d.style.strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    switch (d) {
      case RectangleDrawable():
        canvas.drawRect(d.rect, paint);
      case ArrowDrawable():
        _paintArrow(canvas, d, paint);
      case TextDrawable():
        final tp = TextPainter(
          text: TextSpan(
            text: d.text,
            style: TextStyle(color: d.style.color, fontSize: d.style.fontSize),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, d.position);
    }
  }

  void _paintArrow(Canvas canvas, ArrowDrawable d, Paint paint) {
    canvas.drawLine(d.start, d.end, paint);
    final angle = (d.end - d.start).direction;
    const headLen = 14.0;
    const headAngle = 0.5; // radians
    final p1 = d.end -
        Offset.fromDirection(angle - headAngle, headLen);
    final p2 = d.end -
        Offset.fromDirection(angle + headAngle, headLen);
    canvas.drawLine(d.end, p1, paint);
    canvas.drawLine(d.end, p2, paint);
  }

  void _paintSelection(Canvas canvas, Rect bounds) {
    final r = bounds.inflate(4);
    final line = Paint()
      ..color = const Color(0xFF2196F3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(r, line);
    final handle = Paint()..color = const Color(0xFF2196F3);
    for (final c in [r.topLeft, r.topRight, r.bottomLeft, r.bottomRight]) {
      canvas.drawCircle(c, 4, handle);
    }
  }

  @override
  bool shouldRepaint(DrawablePainter old) =>
      old.drawables != drawables || old.selectedIndex != selectedIndex;
}
