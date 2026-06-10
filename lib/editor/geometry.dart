import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

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

/// The two "bridge" sides of the convex hull of two disjoint axis-aligned rects
/// [a] and [b]: each returned segment joins one corner of [a] to one corner of
/// [b], forming the outer connecting lines (a magnifier "cone" with no middle
/// gap). Returns the (usually two) hull edges that cross between the rects;
/// empty/fewer if one rect contains the other.
List<(Offset, Offset)> hullBridges(Rect a, Rect b) {
  final aCorners = <Offset>[a.topLeft, a.topRight, a.bottomRight, a.bottomLeft];
  final hull = _convexHull([...aCorners, b.topLeft, b.topRight, b.bottomRight, b.bottomLeft]);
  bool inA(Offset p) => aCorners.contains(p);
  final bridges = <(Offset, Offset)>[];
  for (var i = 0; i < hull.length; i++) {
    final p = hull[i];
    final q = hull[(i + 1) % hull.length];
    if (inA(p) != inA(q)) bridges.add((p, q));
  }
  return bridges;
}

/// Convex hull (counter-clockwise) of [points] via Andrew's monotone chain;
/// collinear interior points are dropped. Pure so the magnify connector geometry
/// is unit-testable.
List<Offset> _convexHull(List<Offset> points) {
  final pts = [...points]
    ..sort((p, q) => p.dx != q.dx ? p.dx.compareTo(q.dx) : p.dy.compareTo(q.dy));
  if (pts.length <= 2) return pts;
  double cross(Offset o, Offset a, Offset b) =>
      (a.dx - o.dx) * (b.dy - o.dy) - (a.dy - o.dy) * (b.dx - o.dx);
  final lower = <Offset>[];
  for (final p in pts) {
    while (lower.length >= 2 &&
        cross(lower[lower.length - 2], lower.last, p) <= 0) {
      lower.removeLast();
    }
    lower.add(p);
  }
  final upper = <Offset>[];
  for (final p in pts.reversed) {
    while (upper.length >= 2 &&
        cross(upper[upper.length - 2], upper.last, p) <= 0) {
      upper.removeLast();
    }
    upper.add(p);
  }
  lower.removeLast();
  upper.removeLast();
  return [...lower, ...upper];
}
