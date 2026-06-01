import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/draw_style.dart';
import 'package:glimpr/editor/drawable.dart';
import 'package:glimpr/editor/drawable_painter.dart';

/// Smoke test: paint() must run for every drawable variant without throwing.
/// This exercises the real paint code paths (drawOval/drawLine/drawPath/
/// TextPainter/step circle + RectShaped selection handles) — but never calls
/// picture.toImage (which hangs headless), so it stays fast and reliable.
void main() {
  const style = DrawStyle();

  final everyType = <Drawable>[
    const RectangleDrawable(Rect.fromLTWH(10, 10, 40, 30), style),
    const EllipseDrawable(Rect.fromLTWH(60, 10, 40, 30), style),
    const ArrowDrawable(Offset(10, 60), Offset(60, 90), style),
    const LineDrawable(Offset(70, 60), Offset(120, 90), style),
    const HighlighterDrawable(Offset(10, 100), Offset(120, 100), style),
    const PenDrawable([
      Offset(10, 120),
      Offset(40, 140),
      Offset(70, 120),
    ], style),
    TextDrawable.plain(const Offset(10, 150), 'hi', style),
    StepDrawable(const Offset(160, 40), 12, style),
    // Raster regions with no pre-computed image -> the painter draws a neutral
    // placeholder (the null-source guard) rather than throwing.
    const BlurDrawable(Rect.fromLTWH(180, 80, 50, 40), style),
    const PixelateDrawable(Rect.fromLTWH(180, 130, 50, 40), style),
  ];

  testWidgets('paints every drawable type (ellipse selected -> handles)', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CustomPaint(
          size: const Size(300, 300),
          painter: DrawablePainter(drawables: everyType, selectedIndex: 1),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('selecting a move-only drawable skips corner handles', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CustomPaint(
          size: const Size(300, 300),
          // index 2 == ArrowDrawable (not RectShaped) -> no handles, no throw.
          painter: DrawablePainter(drawables: everyType, selectedIndex: 2),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
