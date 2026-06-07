import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../editor/drawable.dart';
import '../editor/drawable_painter.dart';
import '../theme/glimpr_theme.dart';
import 'hud_lines.dart';

/// Half-length of each reticle plus-arm (logical px). Shared so the crosshair can
/// leave a matching gap around the cursor where the reticle sits.
const double kReticleArm = 9.0;

/// Full-screen crosshair lines through [cursor] (logical coords). Two-tone marching
/// ants (see [drawMarchingLine]) so a thin line stays visible on any background.
/// When [hole] > 0 each line is split to leave a clear square of that radius around
/// the cursor, so the overlaid [ReticlePainter] reads cleanly in the centre.
class CrosshairPainter extends CustomPainter {
  final Offset cursor;
  final ValueListenable<double>? march;
  final double hole;
  const CrosshairPainter(this.cursor, {this.march, this.hole = 0})
    : super(repaint: march);

  @override
  void paint(Canvas canvas, Size size) {
    final phase = (march?.value ?? 0) * kHudDashPeriod;
    final cx = cursor.dx + 0.5;
    final cy = cursor.dy + 0.5;
    if (hole <= 0) {
      drawMarchingLine(canvas, Offset(0, cy), Offset(size.width, cy),
          phase: phase);
      drawMarchingLine(canvas, Offset(cx, 0), Offset(cx, size.height),
          phase: phase);
      return;
    }
    // Split each line around the cursor, leaving a clear centre for the reticle.
    drawMarchingLine(canvas, Offset(0, cy), Offset(cx - hole, cy), phase: phase);
    drawMarchingLine(canvas, Offset(cx + hole, cy), Offset(size.width, cy),
        phase: phase);
    drawMarchingLine(canvas, Offset(cx, 0), Offset(cx, cy - hole), phase: phase);
    drawMarchingLine(canvas, Offset(cx, cy + hole), Offset(cx, size.height),
        phase: phase);
  }

  @override
  bool shouldRepaint(CrosshairPainter old) =>
      old.cursor != cursor || old.march != march || old.hole != hole;
}

/// A SMALL inverting reticle (a short plus) drawn at [cursor] — the precise-aim
/// cursor that replaces the system arrow for the drawing tools (rectangle, arrow,
/// pen, etc.). The region tools (crop / blur / pixelate) use the full-screen
/// [CrosshairPainter] + loupe instead. Shares the HUD line identity (white +
/// inverting blend + width) with the crosshair, but stays SOLID on purpose (no
/// marching ants) — a steady aim point distinct from the animated region lines.
class ReticlePainter extends CustomPainter {
  final Offset cursor;
  final double arm; // half-length of each plus stroke, in logical px
  const ReticlePainter(this.cursor, {this.arm = kReticleArm});

  @override
  void paint(Canvas canvas, Size size) {
    final p = hudReticlePaint();
    canvas.drawLine(
      Offset(cursor.dx - arm, cursor.dy + 0.5),
      Offset(cursor.dx + arm, cursor.dy + 0.5),
      p,
    );
    canvas.drawLine(
      Offset(cursor.dx + 0.5, cursor.dy - arm),
      Offset(cursor.dx + 0.5, cursor.dy + arm),
      p,
    );
  }

  @override
  bool shouldRepaint(ReticlePainter old) =>
      old.cursor != cursor || old.arm != arm;
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
    final tp = TextPainter(
      text: span,
      textDirection: TextDirection.ltr,
      strutStyle: StrutStyle.disabled, // match the inline field's layout
    )..layout();
    // Text-selection highlight in the brand accent (kept translucent so the
    // glyphs underneath stay readable).
    final paint = Paint()..color = GlimprTokens.accent.withValues(alpha: 0.33);
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
  // Drawables + whole-frame blur/pixelate, so the loupe shows the COMPOSITED
  // result (e.g. a committed blur region reads as blurred, matching the screen
  // and the export) instead of the raw frozen pixels. [logicalSize] is the
  // display's logical size (the painter stretches the whole-frame masks across
  // it). Empty list = plain magnifier (e.g. unit tests).
  final List<Drawable> drawables;
  final ui.Image? blurredFull;
  final ui.Image? pixelatedFull;
  final Size logicalSize;
  const LoupePainter({
    required this.image,
    required this.cursorLogical,
    required this.scaleFactor,
    this.zoom = 8,
    this.drawables = const [],
    this.blurredFull,
    this.pixelatedFull,
    this.logicalSize = Size.zero,
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
      center: Offset(centerPx.dx, centerPx.dy),
      width: spanPx,
      height: spanPx,
    );
    canvas.drawImageRect(
      image,
      src,
      dst,
      Paint()..filterQuality = FilterQuality.none,
    );

    // Magnify the annotation layer on top of the frozen pixels, mapped so that
    // logical coords land 1:1 with the frozen region above (1 logical px =
    // scaleFactor*zoom loupe px, centered on the cursor). This makes committed
    // blur/pixelate (and other drawables) appear in the loupe as on screen.
    if (drawables.isNotEmpty && !logicalSize.isEmpty) {
      canvas.save();
      canvas.translate(size.width / 2, size.height / 2);
      canvas.scale(scaleFactor * zoom);
      canvas.translate(-cursorLogical.dx, -cursorLogical.dy);
      DrawablePainter(
        drawables: drawables,
        blurredFull: blurredFull,
        pixelatedFull: pixelatedFull,
      ).paint(canvas, logicalSize);
      canvas.restore();
    }

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
        center: size.center(Offset.zero),
        width: zoom,
        height: zoom,
      ),
      marker,
    );
    canvas.restore();

    // Border (inverting blend so the loupe frame is visible on any background).
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = const Color(0xFFFFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..blendMode = BlendMode.difference,
    );
  }

  @override
  bool shouldRepaint(LoupePainter old) =>
      old.cursorLogical != cursorLogical ||
      old.image != image ||
      old.zoom != zoom ||
      old.drawables != drawables ||
      old.blurredFull != blurredFull ||
      old.pixelatedFull != pixelatedFull;
}

// Shared HUD pill (loupe readout + box-size label): dark body + thin light frame,
// matching the loupe. Wrapped in a transparent Material so its text always gets a
// real default style — identically in the overlay (no Scaffold ancestor) and the
// image editor — instead of Flutter's "missing DefaultTextStyle" yellow underline.
const Color _kHudPillColor = Color(0xF2202020);
const Color _kHudPillBorder = Color(0x55FFFFFF);
const TextStyle _kHudText = TextStyle(
  color: Color(0xFFFFFFFF),
  fontSize: 11,
  height: 1.3,
  decoration: TextDecoration.none, // kill the stray fallback underline
  fontFeatures: [FontFeature.tabularFigures()], // steady digit columns
);

Widget _hudPill(Widget child) => IgnorePointer(
  child: Material(
    type: MaterialType.transparency,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: _kHudPillColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _kHudPillBorder, width: 1),
      ),
      child: child,
    ),
  ),
);

/// The cursor's pixel position, shown directly under the loupe (NATIVE pixels —
/// matching the loupe's pixel grid and the saved image). The same widget/style is
/// used by the overlay and the image editor so the two surfaces look identical.
class LoupeReadout extends StatelessWidget {
  final int x;
  final int y;
  const LoupeReadout({super.key, required this.x, required this.y});

  @override
  Widget build(BuildContext context) =>
      _hudPill(Text('$x, $y', style: _kHudText));
}

/// The box-size readout (W × H, NATIVE pixels), shown beside the selection's
/// cursor (moving) corner during a drag. Same pill style as [LoupeReadout]; the
/// `×` keeps it self-explanatory.
class BoxSizeLabel extends StatelessWidget {
  final int w;
  final int h;
  const BoxSizeLabel({super.key, required this.w, required this.h});

  @override
  Widget build(BuildContext context) =>
      _hudPill(Text('$w × $h', style: _kHudText.copyWith(fontWeight: FontWeight.w700)));
}

/// The drag-start origin (NATIVE pixels), shown beside the selection's start
/// corner. [cornerLeft]/[cornerTop] say which corner the start point is, so the
/// arrow points back at it (the pill sits just outside that corner of the box).
class StartCoordLabel extends StatelessWidget {
  final int startX;
  final int startY;
  final bool cornerLeft;
  final bool cornerTop;
  const StartCoordLabel({
    super.key,
    required this.startX,
    required this.startY,
    required this.cornerLeft,
    required this.cornerTop,
  });

  // The pill sits diagonally OUTSIDE the corner, so the arrow points inward
  // (toward the box centre) at the start point it labels.
  IconData get _arrow => cornerTop
      ? (cornerLeft ? Icons.south_east : Icons.south_west)
      : (cornerLeft ? Icons.north_east : Icons.north_west);

  @override
  Widget build(BuildContext context) => _hudPill(
    Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(_arrow, size: 11, color: const Color(0xFFFFFFFF)),
        const SizedBox(width: 2),
        Text('$startX, $startY', style: _kHudText),
      ],
    ),
  );
}

/// A snap highlight around a hovered window: a single rounded outline drawn with
/// the shared HUD line identity (white + inverting BlendMode.difference, so a thin
/// line stays visible on any backdrop) and animated as marching ants via [march].
/// Center is untouched (transparent), so the window content stays fully visible;
/// rounded corners approximate native window radii (macOS/Windows).
class WindowHighlightPainter extends CustomPainter {
  final Rect rect;
  final double radius;
  final ValueListenable<double>? march;
  const WindowHighlightPainter(this.rect, {this.radius = 10, this.march})
    : super(repaint: march);

  @override
  void paint(Canvas canvas, Size size) {
    final phase = (march?.value ?? 0) * kHudDashPeriod;
    drawMarchingPolyline(
      canvas,
      roundedRectPolyline(rect, radius),
      phase: phase,
    );
  }

  @override
  bool shouldRepaint(WindowHighlightPainter old) =>
      old.rect != rect || old.radius != radius || old.march != march;
}
