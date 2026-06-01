import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// Full-screen crosshair lines through [cursor] (logical coords). Uses an
/// inverting blend (BlendMode.difference with white) so the line flips whatever
/// is behind it and stays visible over any background, bright or dark.
class CrosshairPainter extends CustomPainter {
  final Offset cursor;
  const CrosshairPainter(this.cursor);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..strokeWidth = 1
      ..blendMode = BlendMode.difference;
    canvas.drawLine(
        Offset(0, cursor.dy + 0.5), Offset(size.width, cursor.dy + 0.5), p);
    canvas.drawLine(
        Offset(cursor.dx + 0.5, 0), Offset(cursor.dx + 0.5, size.height), p);
  }

  @override
  bool shouldRepaint(CrosshairPainter old) => old.cursor != cursor;
}

/// Paints the text-selection highlight ourselves so the selected range stays
/// visible even when the inline field is blurred (e.g. while typing a pt value
/// in the toolbar). [span] is the laid-out text, [origin] its top-left.
class TextSelectionPainter extends CustomPainter {
  final InlineSpan span;
  final Offset origin;
  final TextSelection selection;
  const TextSelectionPainter({
    required this.span,
    required this.origin,
    required this.selection,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (!selection.isValid || selection.isCollapsed) return;
    final tp = TextPainter(text: span, textDirection: TextDirection.ltr)
      ..layout();
    final paint = Paint()..color = const Color(0x553A7BFF);
    for (final box in tp.getBoxesForSelection(selection)) {
      canvas.drawRect(box.toRect().shift(origin), paint);
    }
  }

  @override
  bool shouldRepaint(TextSelectionPainter old) => true;
}

/// A pixel-magnifier loupe of [image] (native pixels) centered on [cursorLogical]
/// (logical coords; native = logical * [scaleFactor]). Drawn crisp (no filter)
/// with a pixel grid and a center-pixel marker, sized to the painter's box.
class LoupePainter extends CustomPainter {
  final ui.Image image;
  final Offset cursorLogical;
  final double scaleFactor;
  final double zoom;
  const LoupePainter({
    required this.image,
    required this.cursorLogical,
    required this.scaleFactor,
    this.zoom = 8,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final dst = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(dst, const Radius.circular(8));
    canvas.save();
    canvas.clipRRect(rrect);
    canvas.drawRect(dst, Paint()..color = const Color(0xFF202020));

    final centerPx = cursorLogical * scaleFactor; // native px under the cursor
    final spanPx = size.width / zoom; // native px visible across the loupe
    final src = Rect.fromCenter(
        center: Offset(centerPx.dx, centerPx.dy), width: spanPx, height: spanPx);
    canvas.drawImageRect(
        image, src, dst, Paint()..filterQuality = FilterQuality.none);

    // Pixel grid (one cell per source pixel) — inverting blend so the lines
    // show over any magnified content.
    final grid = Paint()
      ..color = const Color(0x66FFFFFF)
      ..strokeWidth = 1
      ..blendMode = BlendMode.difference;
    for (double x = 0; x <= size.width; x += zoom) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (double y = 0; y <= size.height; y += zoom) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    // Center-pixel marker (inverting blend — visible over any pixel).
    final marker = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..blendMode = BlendMode.difference;
    canvas.drawRect(
        Rect.fromCenter(
            center: size.center(Offset.zero), width: zoom, height: zoom),
        marker);
    canvas.restore();

    // Border (inverting blend so the loupe frame is visible on any background).
    canvas.drawRRect(
        rrect,
        Paint()
          ..color = const Color(0xFFFFFFFF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..blendMode = BlendMode.difference);
  }

  @override
  bool shouldRepaint(LoupePainter old) =>
      old.cursorLogical != cursorLogical ||
      old.image != image ||
      old.zoom != zoom;
}
