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
    case EllipseDrawable():
      return _hitsEllipse(d.rect, p, d.style.strokeWidth);
    case TextDrawable():
      return d.bounds.contains(p);
    case ArrowDrawable():
      return _distanceToSegment(p, d.start, d.end) <= _band(d.style.strokeWidth);
    case LineDrawable():
      return _distanceToSegment(p, d.start, d.end) <= _band(d.style.strokeWidth);
    case HighlighterDrawable():
      return _distanceToSegment(p, d.start, d.end) <=
          _band(d.style.strokeWidth * 5);
    case PenDrawable():
      return _hitsPolyline(d.points, p, _band(d.style.strokeWidth));
    case StepDrawable():
      return (p - d.center).distance <= d.radius;
    case BlurDrawable():
      return d.rect.contains(p);
    case PixelateDrawable():
      return d.rect.contains(p);
    case ImageDrawable():
      return d.rect.contains(p);
  }
}

/// Grab band around a stroke: at least the base tolerance, wider for thick lines.
double _band(double strokeWidth) =>
    strokeWidth / 2 > _kArrowHitTolerance ? strokeWidth / 2 : _kArrowHitTolerance;

/// Point inside the (stroke-inflated) ellipse inscribed in [rect].
bool _hitsEllipse(Rect rect, Offset p, double stroke) {
  final r = rect.inflate(stroke);
  final rx = r.width / 2, ry = r.height / 2;
  if (rx <= 0 || ry <= 0) return false;
  final dx = (p.dx - r.center.dx) / rx;
  final dy = (p.dy - r.center.dy) / ry;
  return dx * dx + dy * dy <= 1;
}

bool _hitsPolyline(List<Offset> pts, Offset p, double tol) {
  if (pts.isEmpty) return false;
  if (pts.length == 1) return (p - pts.first).distance <= tol;
  for (var i = 0; i < pts.length - 1; i++) {
    if (_distanceToSegment(p, pts[i], pts[i + 1]) <= tol) return true;
  }
  return false;
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
