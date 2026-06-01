import 'dart:ui';
import 'drawable.dart';

const double _kArrowHitTolerance = 8;

/// Returns the index of the topmost (last-painted) drawable hit by [p], or null.
/// When [where] is given, only drawables satisfying it are considered (used to
/// hit-test against a single tool's own drawable type).
int? hitTestTop(List<Drawable> drawables, Offset p,
    {bool Function(Drawable)? where}) {
  for (var i = drawables.length - 1; i >= 0; i--) {
    if (where != null && !where(drawables[i])) continue;
    if (_hits(drawables[i], p)) return i;
  }
  return null;
}

bool _hits(Drawable d, Offset p) {
  switch (d) {
    case RectangleDrawable():
      return d.rect.inflate(d.style.strokeWidth).contains(p);
    case TextDrawable():
      return d.bounds.contains(p);
    case ArrowDrawable():
      return _distanceToSegment(p, d.start, d.end) <= _kArrowHitTolerance;
  }
}

double _distanceToSegment(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final lenSq = ab.dx * ab.dx + ab.dy * ab.dy;
  if (lenSq == 0) return (p - a).distance;
  var t = ((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / lenSq;
  t = t.clamp(0.0, 1.0);
  final proj = Offset(a.dx + t * ab.dx, a.dy + t * ab.dy);
  return (p - proj).distance;
}
