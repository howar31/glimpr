import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

/// Shared visual identity for the precise-aim HUD lines drawn over a capture /
/// edit session: the full-screen crop crosshair, the crop selection-box border,
/// and the window-snap highlight. All three are WHITE drawn with an inverting
/// blend (BlendMode.difference) so a thin line stays visible on any background,
/// share one stroke width, and animate as "marching ants" (a dash pattern that
/// crawls along the path).
///
/// The small drawing-tool reticle reuses the colour / blend / width but stays
/// SOLID (no dash) on purpose — see [ReticlePainter] in crop_hud.dart.
///
/// PERF: every painter batches its dashes into a SINGLE [Canvas.drawRawPoints]
/// call (no per-dash [Path] allocation, no [PathMetric.extractPath]); the marching
/// motion is driven by a ~30fps notifier (see editor_core), not a 60fps vsync
/// ticker — a naive per-frame extractPath + Path.combine version dropped frames.
const Color kHudLineColor = Color(0xFFFFFFFF); // the "lit" pass
const Color kHudInk = Color(0xFF000000); // the "ink" pass (fills the gaps)
const double kHudLineWidth = 1.0;

/// Dash geometry in logical px: dash length + gap. Kept EQUAL so the two-tone
/// marching pattern is evenly black/white (classic marching ants). One period =
/// [kHudDash] + [kHudGap]. Tunable.
const double kHudDash = 5.0;
const double kHudGap = 5.0;
const double kHudDashPeriod = kHudDash + kHudGap;

/// One full marching-ants cycle: the dash phase advances by exactly one
/// [kHudDashPeriod] over this duration, so the dashes appear to crawl along the
/// path. Tunable.
const Duration kHudMarchDuration = Duration(milliseconds: 600);

/// Repaint cadence of the marching-ants animation. ~30fps reads as smooth flow
/// while halving wake-ups / energy versus a 60fps vsync ticker. Tunable.
const Duration kHudMarchTick = Duration(milliseconds: 33);

/// The marching lines use a TWO-TONE (white + black) dash pattern over the cheap
/// fixed-function `srcOver` blend, NOT an inverting `BlendMode.difference`. Reason:
/// difference is an Impeller "advanced blend" whose framebuffer-readback cost
/// scales with the drawn shape's bounding-box area and is recomputed every
/// marching-ants frame — so a near-full-screen crop outline tanked the framerate.
/// Interleaving a white dash with a black gap-fill keeps the line visible on any
/// background (one tone always contrasts) without any readback.
Paint _strokePaint(Color color) => Paint()
  ..color = color
  ..style = PaintingStyle.stroke
  ..strokeWidth = kHudLineWidth;

/// The small drawing-tool reticle KEEPS the inverting blend: it is tiny and never
/// animates, so its advanced-blend readback area / frequency is negligible — and
/// it preserves the reticle's distinct inverting identity. See [ReticlePainter].
Paint hudReticlePaint() => Paint()
  ..color = kHudLineColor
  ..style = PaintingStyle.stroke
  ..strokeWidth = kHudLineWidth
  ..blendMode = BlendMode.difference;

/// Pure dash math: the "on" intervals to draw along a line / contour of [length],
/// given the [dash] / [gap] pattern shifted by [phase] (logical px — driving the
/// marching-ants motion). Each interval is clamped to `[0, length]`; increasing
/// [phase] crawls the dashes in the +distance direction. Deterministic → unit
/// tested.
List<({double start, double end})> dashOnIntervals(
  double length, {
  double dash = kHudDash,
  double gap = kHudGap,
  double phase = 0,
}) {
  final result = <({double start, double end})>[];
  final period = dash + gap;
  if (length <= 0 || dash <= 0 || period <= 0) return result;
  // First dash start at/just before distance 0, then step by one period.
  double s = phase % period;
  if (s < 0) s += period; // [0, period)
  s -= period; // [-period, 0)
  while (s < length) {
    final a = s < 0 ? 0.0 : s;
    final b = (s + dash) > length ? length : (s + dash);
    if (b > a) result.add((start: a, end: b));
    s += period;
  }
  return result;
}

/// Appends the dash endpoints (point pairs, for [PointMode.lines]) along the
/// straight segment [a]→[b] to [out], shifted by [phase].
void addDashedLinePoints(
  List<double> out,
  Offset a,
  Offset b, {
  double dash = kHudDash,
  double gap = kHudGap,
  double phase = 0,
}) {
  final delta = b - a;
  final length = delta.distance;
  if (length == 0) return;
  final dir = delta / length;
  for (final seg in dashOnIntervals(length, dash: dash, gap: gap, phase: phase)) {
    final p1 = a + dir * seg.start;
    final p2 = a + dir * seg.end;
    out
      ..add(p1.dx)
      ..add(p1.dy)
      ..add(p2.dx)
      ..add(p2.dy);
  }
}

/// Appends the dash endpoints along the polyline [pts] to [out], with the phase
/// applied to ONE continuous arc length over the whole contour (so the dashes
/// flow smoothly across corners). [closed] joins the last vertex back to the
/// first. A dash spanning a corner is split into per-edge sub-segments.
void addDashedPolylinePoints(
  List<double> out,
  List<Offset> pts, {
  bool closed = true,
  double dash = kHudDash,
  double gap = kHudGap,
  double phase = 0,
}) {
  if (pts.length < 2) return;
  // Edges with their cumulative start distance along the contour.
  final edges = <({Offset a, Offset b, double start, double len})>[];
  double acc = 0;
  final n = closed ? pts.length : pts.length - 1;
  for (var i = 0; i < n; i++) {
    final a = pts[i];
    final b = pts[(i + 1) % pts.length];
    final len = (b - a).distance;
    if (len > 0) {
      edges.add((a: a, b: b, start: acc, len: len));
      acc += len;
    }
  }
  if (acc <= 0) return;
  for (final on in dashOnIntervals(acc, dash: dash, gap: gap, phase: phase)) {
    for (final e in edges) {
      final e1 = e.start + e.len;
      final a0 = on.start > e.start ? on.start : e.start;
      final b0 = on.end < e1 ? on.end : e1;
      if (b0 <= a0) continue;
      final dir = (e.b - e.a) / e.len;
      final p1 = e.a + dir * (a0 - e.start);
      final p2 = e.a + dir * (b0 - e.start);
      out
        ..add(p1.dx)
        ..add(p1.dy)
        ..add(p2.dx)
        ..add(p2.dy);
    }
  }
}

void _rawLines(Canvas canvas, List<double> out, Color color) {
  if (out.isNotEmpty) {
    canvas.drawRawPoints(
      PointMode.lines,
      Float32List.fromList(out),
      _strokePaint(color),
    );
  }
}

/// Draws a TWO-TONE marching-ants straight line [a]→[b]: white dashes at [phase]
/// plus black dashes filling the gaps, so it reads on any background. Two cheap
/// [drawRawPoints] calls, no advanced blend.
void drawMarchingLine(Canvas canvas, Offset a, Offset b, {double phase = 0}) {
  final lit = <double>[];
  addDashedLinePoints(lit, a, b, dash: kHudDash, gap: kHudGap, phase: phase);
  _rawLines(canvas, lit, kHudLineColor);
  final ink = <double>[];
  addDashedLinePoints(
    ink,
    a,
    b,
    dash: kHudGap,
    gap: kHudDash,
    phase: phase + kHudDash,
  );
  _rawLines(canvas, ink, kHudInk);
}

/// Draws a TWO-TONE marching-ants polyline (e.g. a rect or rounded-rect
/// perimeter): white dashes plus black gap-fills over one continuous arc length.
void drawMarchingPolyline(
  Canvas canvas,
  List<Offset> pts, {
  bool closed = true,
  double phase = 0,
}) {
  final lit = <double>[];
  addDashedPolylinePoints(
    lit,
    pts,
    closed: closed,
    dash: kHudDash,
    gap: kHudGap,
    phase: phase,
  );
  _rawLines(canvas, lit, kHudLineColor);
  final ink = <double>[];
  addDashedPolylinePoints(
    ink,
    pts,
    closed: closed,
    dash: kHudGap,
    gap: kHudDash,
    phase: phase + kHudDash,
  );
  _rawLines(canvas, ink, kHudInk);
}

/// A clockwise polyline tracing [rect] with rounded corners of [radius] (each
/// corner tessellated into [cornerSteps] segments). Feed to [drawMarchingPolyline]
/// — far cheaper than dashing an RRect via PathMetrics every frame.
List<Offset> roundedRectPolyline(
  Rect rect,
  double radius, {
  int cornerSteps = 4,
}) {
  final r = radius
      .clamp(0.0, math.min(rect.width, rect.height) / 2)
      .toDouble();
  if (r <= 0) {
    return [rect.topLeft, rect.topRight, rect.bottomRight, rect.bottomLeft];
  }
  final pts = <Offset>[];
  void arc(Offset center, double startDeg, double endDeg) {
    for (var i = 0; i <= cornerSteps; i++) {
      final t = i / cornerSteps;
      final ang = (startDeg + (endDeg - startDeg) * t) * math.pi / 180.0;
      pts.add(
        Offset(center.dx + r * math.cos(ang), center.dy + r * math.sin(ang)),
      );
    }
  }

  final l = rect.left, t = rect.top, rr = rect.right, b = rect.bottom;
  arc(Offset(l + r, t + r), 180, 270); // top-left, ends at (l+r, t)
  arc(Offset(rr - r, t + r), 270, 360); // top-right
  arc(Offset(rr - r, b - r), 0, 90); // bottom-right
  arc(Offset(l + r, b - r), 90, 180); // bottom-left
  return pts;
}
