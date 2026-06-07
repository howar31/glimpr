import 'dart:math' as math;
import 'dart:ui';

import 'draw_style.dart';

/// Smooth curve + line-style helpers for the Segmented line tools (line / arrow /
/// highlighter). A shape is a list of control points (first = start, last = end,
/// middle = interior); the rendered curve is a Catmull-Rom spline THROUGH all of
/// them (so every handle sits on the curve). 2 points → a straight line.

Offset _cubic(Offset a, Offset b, Offset c, Offset d, double t) {
  final mt = 1 - t;
  final w0 = mt * mt * mt;
  final w1 = 3 * mt * mt * t;
  final w2 = 3 * mt * t * t;
  final w3 = t * t * t;
  return Offset(
    w0 * a.dx + w1 * b.dx + w2 * c.dx + w3 * d.dx,
    w0 * a.dy + w1 * b.dy + w2 * c.dy + w3 * d.dy,
  );
}

/// The two cubic control points for the Catmull-Rom segment p1→p2 (neighbours
/// p0, p3; endpoints are clamped by the caller).
({Offset cp1, Offset cp2}) _segmentControls(
  Offset p0,
  Offset p1,
  Offset p2,
  Offset p3,
) =>
    (cp1: p1 + (p2 - p0) / 6, cp2: p2 - (p3 - p1) / 6);

/// A smooth Catmull-Rom spline THROUGH [pts], as cubic Béziers. 0/1 points → a
/// degenerate path; 2 points → a straight line.
Path catmullRomPath(List<Offset> pts) {
  final path = Path();
  if (pts.isEmpty) return path;
  path.moveTo(pts.first.dx, pts.first.dy);
  if (pts.length == 1) return path;
  if (pts.length == 2) {
    path.lineTo(pts[1].dx, pts[1].dy);
    return path;
  }
  for (var i = 0; i < pts.length - 1; i++) {
    final p0 = pts[i == 0 ? 0 : i - 1];
    final p1 = pts[i];
    final p2 = pts[i + 1];
    final p3 = pts[i + 2 < pts.length ? i + 2 : pts.length - 1];
    final c = _segmentControls(p0, p1, p2, p3);
    path.cubicTo(c.cp1.dx, c.cp1.dy, c.cp2.dx, c.cp2.dy, p2.dx, p2.dy);
  }
  return path;
}

/// The spline flattened to a polyline ([perSegment] samples per span), for
/// hit-testing and the highlighter band. 2 points → the two points themselves.
List<Offset> sampleCatmullRom(List<Offset> pts, {int perSegment = 12}) {
  if (pts.length <= 2) return List.of(pts);
  final out = <Offset>[pts.first];
  for (var i = 0; i < pts.length - 1; i++) {
    final p0 = pts[i == 0 ? 0 : i - 1];
    final p1 = pts[i];
    final p2 = pts[i + 1];
    final p3 = pts[i + 2 < pts.length ? i + 2 : pts.length - 1];
    final c = _segmentControls(p0, p1, p2, p3);
    for (var s = 1; s <= perSegment; s++) {
      out.add(_cubic(p1, c.cp1, c.cp2, p2, s / perSegment));
    }
  }
  return out;
}

/// Unit tangent pointing OUTWARD at the curve's end ([atEnd]) or start, for
/// orienting an arrowhead. Falls back to +x for a degenerate shape.
Offset curveTangent(List<Offset> pts, {required bool atEnd}) {
  final poly = sampleCatmullRom(pts);
  if (poly.length < 2) return const Offset(1, 0);
  final a = atEnd ? poly[poly.length - 2] : poly[1];
  final b = atEnd ? poly.last : poly.first;
  final d = b - a;
  final len = d.distance;
  return len == 0 ? const Offset(1, 0) : d / len;
}

/// [interior] control points spread evenly along the straight [start]→[end] line
/// (the initial shape of a freshly drawn segment), returned as the full point
/// list [start, ...interior, end].
List<Offset> seedInterior(Offset start, Offset end, int interior) {
  final pts = <Offset>[start];
  for (var i = 1; i <= interior; i++) {
    pts.add(Offset.lerp(start, end, i / (interior + 1))!);
  }
  pts.add(end);
  return pts;
}

/// Re-seed [interior] control points evenly BY ARC LENGTH along the current
/// spline of [pts], preserving the overall shape + the endpoints. Used when the
/// curve-points count changes on a selected shape.
List<Offset> resampleInterior(List<Offset> pts, int interior) {
  final start = pts.first, end = pts.last;
  if (interior <= 0) return [start, end];
  final poly = sampleCatmullRom(pts, perSegment: 24);
  final cum = <double>[0];
  for (var i = 1; i < poly.length; i++) {
    cum.add(cum[i - 1] + (poly[i] - poly[i - 1]).distance);
  }
  final total = cum.last;
  final result = <Offset>[start];
  for (var i = 1; i <= interior; i++) {
    if (total == 0) {
      result.add(start);
    } else {
      result.add(_pointAtLength(poly, cum, total * i / (interior + 1)));
    }
  }
  result.add(end);
  return result;
}

Offset _pointAtLength(List<Offset> poly, List<double> cum, double target) {
  for (var i = 1; i < cum.length; i++) {
    if (cum[i] >= target) {
      final seg = cum[i] - cum[i - 1];
      final t = seg == 0 ? 0.0 : (target - cum[i - 1]) / seg;
      return Offset.lerp(poly[i - 1], poly[i], t)!;
    }
  }
  return poly.last;
}

// ---- line styles ----------------------------------------------------------

enum DashKind { dash, dot, gap }

/// One run of a line-style pattern, length in logical px.
typedef DashRun = ({double len, DashKind kind});

/// The repeating run pattern for [style] at stroke width [w] (lengths scale with
/// w so the look holds at any thickness). Empty = solid (stroke the whole path).
List<DashRun> dashPattern(LineStyle style, double w) {
  switch (style) {
    case LineStyle.solid:
      return const [];
    case LineStyle.dashed:
      return [(len: 4 * w, kind: DashKind.dash), (len: 3 * w, kind: DashKind.gap)];
    case LineStyle.longDash:
      return [(len: 8 * w, kind: DashKind.dash), (len: 4 * w, kind: DashKind.gap)];
    case LineStyle.dotted:
      return [(len: w, kind: DashKind.dot), (len: 2 * w, kind: DashKind.gap)];
    case LineStyle.dashDot:
      return [
        (len: 4 * w, kind: DashKind.dash),
        (len: 2 * w, kind: DashKind.gap),
        (len: w, kind: DashKind.dot),
        (len: 2 * w, kind: DashKind.gap),
      ];
    case LineStyle.dashDotDot:
      return [
        (len: 4 * w, kind: DashKind.dash),
        (len: 2 * w, kind: DashKind.gap),
        (len: w, kind: DashKind.dot),
        (len: 2 * w, kind: DashKind.gap),
        (len: w, kind: DashKind.dot),
        (len: 2 * w, kind: DashKind.gap),
      ];
  }
}

/// Strokes [path] in [style]: solid strokes the whole path; otherwise dashes are
/// extracted sub-paths (stroked with [stroke]) and dots are filled circles of the
/// stroke width. [w] is the stroke width (drives the pattern + dot size).
void drawStyledPath(
  Canvas canvas,
  Path path,
  Paint stroke,
  LineStyle style,
  double w,
) {
  final runs = dashPattern(style, w);
  if (runs.isEmpty) {
    canvas.drawPath(path, stroke);
    return;
  }
  final dots = Paint()
    ..color = stroke.color
    ..isAntiAlias = true;
  final dashPath = Path();
  for (final metric in path.computeMetrics()) {
    final length = metric.length;
    if (length <= 0) continue;
    double pos = 0;
    var i = 0;
    while (pos < length) {
      final run = runs[i % runs.length];
      final end = math.min(pos + run.len, length);
      if (run.kind == DashKind.dash && end > pos) {
        dashPath.addPath(metric.extractPath(pos, end), Offset.zero);
      } else if (run.kind == DashKind.dot) {
        final mid = pos + run.len / 2;
        if (mid <= length) {
          final tan = metric.getTangentForOffset(mid);
          if (tan != null) canvas.drawCircle(tan.position, w / 2, dots);
        }
      }
      pos += run.len;
      i++;
    }
  }
  canvas.drawPath(dashPath, stroke);
}

// ---- pen smoothing --------------------------------------------------------

/// Fixed minimum spacing (logical px) used to decimate a freehand pen stroke ONCE
/// on release. The kept points are then drawn as a Catmull-Rom spline, so the
/// stroke reads smooth while storing / painting / hit-testing far fewer points
/// than the raw pointer samples. A balance of smoothing vs corner fidelity; raise
/// it to simplify (and save) more, lower it to follow the hand more closely.
const double kPenSmoothMinDist = 6;

/// Drop points closer than [minDist] to the last KEPT point, always keeping the
/// first and last. O(n), order-stable. [minDist] <= 0, or 2-or-fewer points →
/// the points unchanged.
List<Offset> decimateByDistance(List<Offset> pts, double minDist) {
  if (minDist <= 0 || pts.length <= 2) return List.of(pts);
  final out = <Offset>[pts.first];
  for (var i = 1; i < pts.length - 1; i++) {
    if ((pts[i] - out.last).distance >= minDist) out.add(pts[i]);
  }
  out.add(pts.last);
  return out;
}
