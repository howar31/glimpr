import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../theme/glimpr_theme.dart';
import 'hud_lines.dart';

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
/// (white + inverting BlendMode.difference, shared width) with the crosshair and
/// window-snap highlight; driven by [march] (a ~30fps phase notifier). Kept apart
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
