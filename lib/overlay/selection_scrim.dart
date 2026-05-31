import 'package:flutter/material.dart';

/// The scrim path: the whole canvas MINUS the (clamped) selection rectangle.
/// `null` selection -> the full canvas (everything dimmed).
Path scrimPath(Size size, Rect? selection) {
  final full = Offset.zero & size;
  final base = Path()..addRect(full);
  if (selection == null) return base;
  final hole = selection.intersect(full);
  if (hole.width <= 0 || hole.height <= 0) return base;
  return Path.combine(
    PathOperation.difference,
    base,
    Path()..addRect(hole),
  );
}

/// Dims everything outside [selection] and outlines it.
class SelectionScrimPainter extends CustomPainter {
  final Rect? selection;
  final Color scrimColor;
  final Color borderColor;

  const SelectionScrimPainter({
    required this.selection,
    this.scrimColor = const Color(0x66000000), // 40% black
    this.borderColor = const Color(0xFF2196F3),
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(scrimPath(size, selection), Paint()..color = scrimColor);
    final sel = selection;
    if (sel != null) {
      final clamped = sel.intersect(Offset.zero & size);
      if (clamped.width > 0 && clamped.height > 0) {
        canvas.drawRect(
          clamped,
          Paint()
            ..color = borderColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
      }
    }
  }

  @override
  bool shouldRepaint(SelectionScrimPainter old) =>
      old.selection != selection ||
      old.scrimColor != scrimColor ||
      old.borderColor != borderColor;
}
