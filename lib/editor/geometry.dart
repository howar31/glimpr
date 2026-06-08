import 'dart:math' as math;
import 'dart:ui' show Offset;

/// Shift-constrain a box drag to a fixed ASPECT (width/height) from anchor [a]
/// toward [p]: grow to reach the cursor on the binding axis, keeping the drag's
/// quadrant. aspect == 1 reduces to a square.
Offset aspectCorner(Offset a, Offset p, double aspect) {
  final dx = p.dx - a.dx;
  final dy = p.dy - a.dy;
  final w = math.max(dx.abs(), dy.abs() * aspect);
  final h = w / aspect;
  return Offset(a.dx + (dx < 0 ? -w : w), a.dy + (dy < 0 ? -h : h));
}
