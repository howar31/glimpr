import 'dart:ui' show PointMode;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../theme/glimpr_theme.dart';
import 'hud_lines.dart';
import 'selection_guides.dart';

/// The scrim path: the whole canvas MINUS the (clamped) selection rectangle.
/// `null` selection -> the full canvas (everything dimmed).
Path scrimPath(Size size, Rect? selection) {
  final full = Offset.zero & size;
  final base = Path()..addRect(full);
  if (selection == null) return base;
  final hole = selection.intersect(full);
  if (hole.width <= 0 || hole.height <= 0) return base;
  return Path.combine(PathOperation.difference, base, Path()..addRect(hole));
}

/// Dims everything outside [selection] (the static scrim FILL only). The marching
/// outline is a SEPARATE painter ([SelectionBorderPainter]) so this — which runs
/// an expensive `Path.combine` difference — repaints only when the selection
/// changes, NOT on every marching-ants frame.
class SelectionScrimPainter extends CustomPainter {
  final Rect? selection;
  final Color scrimColor;

  const SelectionScrimPainter({
    required this.selection,
    this.scrimColor = GlimprTokens.scrim, // unified chrome dim (pure black 40%)
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(scrimPath(size, selection), Paint()..color = scrimColor);
  }

  @override
  bool shouldRepaint(SelectionScrimPainter old) =>
      old.selection != selection || old.scrimColor != scrimColor;
}

/// The crop selection's marching-ants outline. Shares the HUD line identity
/// (two-tone white + black dashes over srcOver, shared width) with the crosshair
/// and window-snap highlight; driven by [march] (a ~30fps phase notifier). Kept apart
/// from the scrim FILL so the cheap line redraw — not the costly scrim — is what
/// repaints each animation frame.
class SelectionBorderPainter extends CustomPainter {
  final Rect? selection;
  final ValueListenable<double>? march;

  const SelectionBorderPainter({required this.selection, this.march})
    : super(repaint: march);

  @override
  void paint(Canvas canvas, Size size) {
    final sel = selection;
    if (sel == null) return;
    final clamped = sel.intersect(Offset.zero & size);
    if (clamped.width <= 0 || clamped.height <= 0) return;
    final phase = (march?.value ?? 0) * kHudDashPeriod;
    drawMarchingPolyline(
      canvas,
      [
        clamped.topLeft,
        clamped.topRight,
        clamped.bottomRight,
        clamped.bottomLeft,
      ],
      phase: phase,
    );
  }

  @override
  bool shouldRepaint(SelectionBorderPainter old) =>
      old.selection != selection || old.march != march;
}

/// Composition guides inside the crop selection: rule-of-thirds grid / corner
/// diagonals (see [guideSegments]) and/or the center mark ([guideCenterMark]).
/// STATIC (no marching phase; repaints only when the rect or options change)
/// so it never competes with the animated border. The LINES are two-tone
/// dashes (white + black gap-fill, like the border) so they read on any
/// background without an advanced blend; the tiny center plus is SOLID and
/// follows [invert] like the reticle (see hudSolidPaints: even a few px of an
/// advanced blend cost a whole-frame readback on Windows).
class SelectionGuidesPainter extends CustomPainter {
  final Rect rect;
  final GuideLines lines;
  final bool center;
  final bool invert; // HudConfig.invertLines

  const SelectionGuidesPainter({
    required this.rect,
    required this.lines,
    required this.center,
    this.invert = false,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final segs = guideSegments(rect, lines: lines);
    if (segs.isNotEmpty) {
      final lit = <double>[];
      final ink = <double>[];
      for (final (a, b) in segs) {
        // +0.5 centres the 1px stroke on the pixel row/column (crisp line).
        final a2 = Offset(a.dx + 0.5, a.dy + 0.5);
        final b2 = Offset(b.dx + 0.5, b.dy + 0.5);
        addDashedLinePoints(lit, a2, b2, dash: kGuideDash, gap: kGuideDash);
        addDashedLinePoints(ink, a2, b2,
            dash: kGuideDash, gap: kGuideDash, phase: kGuideDash);
      }
      _raw(canvas, lit, kHudLineColor);
      _raw(canvas, ink, kHudInk);
    }
    final mark = guideCenterMark(rect, center: center);
    if (mark.isNotEmpty) {
      // Solid, like the reticle: halo pass first, then the white pass.
      for (final p in hudSolidPaints(invert: invert)) {
        for (final (a, b) in mark) {
          canvas.drawLine(
            Offset(a.dx + 0.5, a.dy + 0.5),
            Offset(b.dx + 0.5, b.dy + 0.5),
            p,
          );
        }
      }
    }
  }

  static void _raw(Canvas canvas, List<double> pts, Color color) {
    if (pts.isEmpty) return;
    canvas.drawRawPoints(
      PointMode.lines,
      Float32List.fromList(pts),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = kHudLineWidth,
    );
  }

  @override
  bool shouldRepaint(SelectionGuidesPainter old) =>
      old.rect != rect ||
      old.lines != lines ||
      old.center != center ||
      old.invert != invert;
}
