import 'package:flutter/widgets.dart';

/// A static checkerboard transparency backdrop for the editor canvas, so a
/// transparent PNG reads as "transparent" (the classic two-tone grid) rather
/// than blending into the window glass. Tile colours follow the system
/// appearance — a quiet light/dark grey pair that never competes with the image.
class Checkerboard extends StatelessWidget {
  const Checkerboard({super.key, this.tile = 24, required this.dark});

  /// Side length of one square, in logical pixels.
  final double tile;

  /// Use the dark-appearance tile pair when true, the light pair otherwise.
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _CheckerPainter(tile: tile, dark: dark),
      size: Size.infinite,
    );
  }
}

class _CheckerPainter extends CustomPainter {
  _CheckerPainter({required this.tile, required this.dark});

  final double tile;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    // Two-tone grid: a flat base fill, then the faint checker squares painted
    // over it on alternating cells. The dark board matches the finalized design
    // (a near-black base #0A0E1C with a barely-there white wash); the light pair
    // stays appearance-matched so the board recedes in either theme.
    final base = dark ? const Color(0xFF0A0E1C) : const Color(0xFFE9ECF1);
    final alt = dark ? const Color(0x06FFFFFF) : const Color(0xFFD7DCE4);
    canvas.drawRect(Offset.zero & size, Paint()..color = base);
    final altPaint = Paint()..color = alt;
    final cols = (size.width / tile).ceil();
    final rows = (size.height / tile).ceil();
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        if ((r + c).isEven) continue;
        canvas.drawRect(
          Rect.fromLTWH(c * tile, r * tile, tile, tile),
          altPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_CheckerPainter old) =>
      old.tile != tile || old.dark != dark;
}
