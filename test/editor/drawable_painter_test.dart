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
    const HighlighterDrawable([Offset(10, 100), Offset(120, 100)], style),
    const PenDrawable([
      Offset(10, 120),
      Offset(40, 140),
      Offset(70, 120),
    ], style),
    TextDrawable(const Offset(10, 150), 'hi', style),
    StepDrawable(const Offset(160, 40), 12, style),
    // Raster regions with no pre-computed image -> the painter draws a neutral
    // placeholder (the null-source guard) rather than throwing.
    const BlurDrawable(Rect.fromLTWH(180, 80, 50, 40), style),
    const PixelateDrawable(Rect.fromLTWH(180, 130, 50, 40), style),
  ];

  testWidgets('paints every drawable type without throwing', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CustomPaint(
          size: const Size(300, 300),
          painter: DrawablePainter(drawables: everyType),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  // The selection highlight (flowing outline + handles) is now a separate painter.
  testWidgets('selection: rect-shaped -> flowing box + resize handles', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CustomPaint(
          size: const Size(300, 300),
          // index 1 == EllipseDrawable (RectShaped) -> box + corner handles.
          painter: SelectionHighlightPainter(selected: everyType[1]),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('selection: segment -> endpoint handles', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CustomPaint(
          size: const Size(300, 300),
          // index 2 == ArrowDrawable (Segmented) -> two endpoint handles, no throw.
          painter: SelectionHighlightPainter(selected: everyType[2]),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('selection: move-only -> box, no handles', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CustomPaint(
          size: const Size(300, 300),
          // index 6 == TextDrawable (neither RectShaped nor Segmented) -> a bare
          // flowing box, no handles, no throw.
          painter: SelectionHighlightPainter(selected: everyType[6]),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('selection: null selected -> no-op', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CustomPaint(
          size: const Size(300, 300),
          painter: SelectionHighlightPainter(selected: null),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('curved + styled line tools paint without throwing', (
    tester,
  ) async {
    final shapes = <Drawable>[
      // Curved dotted line (one interior point).
      const LineDrawable(
        Offset(10, 10),
        Offset(110, 10),
        DrawStyle(lineStyle: LineStyle.dotted),
        mids: [Offset(60, 40)],
      ),
      // Curved double-headed dashed arrow (two interior points -> S).
      const ArrowDrawable(
        Offset(10, 60),
        Offset(120, 60),
        DrawStyle(lineStyle: LineStyle.dashed, arrowHeads: ArrowHeads.both),
        mids: [Offset(40, 90), Offset(90, 30)],
      ),
      // Curved highlighter, each texture.
      for (final tex in HighlighterTexture.values)
        HighlighterDrawable(
          const [Offset(10, 130), Offset(70, 160), Offset(130, 130)],
          DrawStyle(texture: tex),
        ),
      // Every line style on a straight arrow.
      for (final ls in LineStyle.values)
        ArrowDrawable(const Offset(150, 10), const Offset(280, 200),
            DrawStyle(lineStyle: ls)),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: CustomPaint(
          size: const Size(320, 320),
          painter: DrawablePainter(drawables: shapes),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
