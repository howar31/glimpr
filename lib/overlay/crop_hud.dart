import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../editor/drawable.dart';
import '../editor/drawable_painter.dart';
import '../theme/glimpr_theme.dart';

/// Full-screen crosshair lines through [cursor] (logical coords). Uses an
/// inverting blend (BlendMode.difference with white) so the line flips whatever
/// is behind it and stays visible over any background, bright or dark.
class CrosshairPainter extends CustomPainter {
  final Offset cursor;
  const CrosshairPainter(this.cursor);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..strokeWidth = 1
      ..blendMode = BlendMode.difference;
    canvas.drawLine(
      Offset(0, cursor.dy + 0.5),
      Offset(size.width, cursor.dy + 0.5),
      p,
    );
    canvas.drawLine(
      Offset(cursor.dx + 0.5, 0),
      Offset(cursor.dx + 0.5, size.height),
      p,
    );
  }

  @override
  bool shouldRepaint(CrosshairPainter old) => old.cursor != cursor;
}

/// A SMALL inverting reticle (a short plus) drawn at [cursor] — the precise-aim
/// cursor that replaces the system arrow for the drawing tools (rectangle, arrow,
/// pen, etc.). The region tools (crop / blur / pixelate) use the full-screen
/// [CrosshairPainter] + loupe instead. Same inverting blend (difference with
/// white) as the full crosshair, so it stays visible over any background.
class ReticlePainter extends CustomPainter {
  final Offset cursor;
  final double arm; // half-length of each plus stroke, in logical px
  const ReticlePainter(this.cursor, {this.arm = 9});

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..strokeWidth = 1
      ..blendMode = BlendMode.difference;
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
        selectedIndex: null,
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

/// The label at a drag selection's bottom-left corner: the box size and its
/// drag-start origin, in NATIVE pixels. Same pill style as [LoupeReadout]; the
/// `×` and the north-west corner icon keep the two lines self-explanatory.
class BoxSizeLabel extends StatelessWidget {
  final int w;
  final int h;
  final int startX;
  final int startY;
  const BoxSizeLabel({
    super.key,
    required this.w,
    required this.h,
    required this.startX,
    required this.startY,
  });

  @override
  Widget build(BuildContext context) => _hudPill(
    Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$w × $h', style: _kHudText.copyWith(fontWeight: FontWeight.w700)),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.north_west, size: 11, color: Color(0xFFFFFFFF)),
            const SizedBox(width: 2),
            Text('$startX, $startY', style: _kHudText),
          ],
        ),
      ],
    ),
  );
}

/// A snap highlight around a hovered window: a single rounded outline drawn with
/// an inverting blend (BlendMode.difference), like the crosshair/reticle, so a
/// thin line stays visible on any backdrop. Center is untouched (transparent),
/// so the window content stays fully visible; rounded corners approximate native
/// window radii (macOS/Windows).
class WindowHighlightPainter extends CustomPainter {
  final Rect rect;
  final double radius;
  const WindowHighlightPainter(this.rect, {this.radius = 10});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(radius)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = const Color(0xFFFFFFFF)
        ..blendMode = BlendMode.difference,
    );
  }

  @override
  bool shouldRepaint(WindowHighlightPainter old) =>
      old.rect != rect || old.radius != radius;
}
