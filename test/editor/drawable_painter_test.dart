import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/draw_style.dart';
import 'package:glimpr/editor/drawable.dart';
import 'package:glimpr/editor/drawable_painter.dart';

import '../support/fake_editor_host.dart' show makeBaseImage;

/// Smoke test: paint() must run for every drawable variant without throwing.
/// This exercises the real paint code paths (drawOval/drawLine/drawPath/
/// TextPainter/step circle + RectShaped selection handles) — but never calls
/// picture.toImage (which hangs headless), so it stays fast and reliable.
void main() {
  const style = DrawStyle();

  // The magnify tool samples this + the spotlight effect layer draws it. Built
  // in setUpAll (real async): decode/toImage never resolve inside testWidgets'
  // fake-async zone (see makeBaseImage's contract).
  late ui.Image base;
  setUpAll(() async => base = await makeBaseImage(64, 64));
  tearDownAll(() => base.dispose());

  final everyType = <Drawable>[
    const RectangleDrawable(Rect.fromLTWH(10, 10, 40, 30), style),
    const EllipseDrawable(Rect.fromLTWH(60, 10, 40, 30), style),
    const ArrowDrawable(Offset(10, 60), Offset(60, 90), style),
    const LineDrawable(Offset(70, 60), Offset(120, 90), style),
    HighlighterDrawable([const Offset(10, 100), const Offset(120, 100)], style),
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

  testWidgets('drop-shadowed variants paint without throwing', (tester) async {
    const s = DrawStyle(shadow: true);
    final shapes = <Drawable>[
      const RectangleDrawable(Rect.fromLTWH(10, 10, 60, 40), s),
      // A filled + shadowed rect: shadow -> fill -> stroke z-order.
      const RectangleDrawable(Rect.fromLTWH(80, 10, 60, 40),
          DrawStyle(shadow: true, fillColor: Color(0x8800AAFF))),
      const EllipseDrawable(Rect.fromLTWH(150, 10, 60, 40), s),
      const ArrowDrawable(Offset(10, 80), Offset(80, 120), s),
      const LineDrawable(Offset(90, 80), Offset(160, 120), s),
      const PenDrawable([Offset(10, 140), Offset(40, 160), Offset(70, 140)], s),
      // Single-point pen dot / arrow dot with a shadow (the degenerate paths).
      const PenDrawable([Offset(230, 150)], s),
      const ArrowDrawable(Offset(250, 150), Offset(250, 150), s),
      StepDrawable(const Offset(200, 40), 14, s),
      // A square step badge with a shadow.
      StepDrawable(const Offset(260, 40), 14,
          const DrawStyle(shadow: true, stepShape: StepShape.square)),
      // Text: glyph-only shadow (no fill / no outline -> the glyph casts it).
      TextDrawable(const Offset(10, 180), 'hi', s),
      // Text: background pill + outline + shadow (the pill casts the shadow).
      TextDrawable(
          const Offset(10, 220),
          'Aa',
          const DrawStyle(
              shadow: true,
              fillColor: Color(0xFF00AA00),
              outlineColor: Color(0xFFFF0000))),
      // Text: outline-only + shadow (the stroke silhouette casts it).
      TextDrawable(const Offset(90, 220), 'Cc',
          const DrawStyle(shadow: true, outlineColor: Color(0xFFAABBCC))),
      // Text: fill + outline, NO shadow (the non-shadow pill/outline branches).
      TextDrawable(const Offset(160, 220), 'Bb',
          const DrawStyle(fillColor: Color(0xFF112233), outlineColor: Color(0xFF445566))),
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

  testWidgets('magnify callout: every MagnifyPart pass paints without throwing',
      (tester) async {
    final m = MagnifyDrawable(
      const Rect.fromLTWH(20, 20, 60, 40),
      const Offset(200, 160),
      const DrawStyle(shadow: true, magnifyConnector: true),
    );
    for (final part in MagnifyPart.values) {
      await tester.pumpWidget(
        MaterialApp(
          home: CustomPaint(
            size: const Size(320, 320),
            painter: DrawablePainter(
              drawables: [m],
              baseImage: base,
              magnifyPart: part,
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull, reason: 'magnify part $part');
    }
    // The chrome-only passes tolerate a null base image (HDR export splits the
    // sampled content out to a native op).
    await tester.pumpWidget(
      MaterialApp(
        home: CustomPaint(
          size: const Size(320, 320),
          painter: DrawablePainter(
              drawables: [m], magnifyPart: MagnifyPart.underChrome),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    // Connector OFF: no bridge lines drawn.
    final noConnector = MagnifyDrawable(
      const Rect.fromLTWH(20, 20, 60, 40),
      const Offset(200, 160),
      const DrawStyle(magnifyConnector: false),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: CustomPaint(
          size: const Size(320, 320),
          painter: DrawablePainter(drawables: [noConnector], baseImage: base),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('selection: magnify -> both boxes + source resize handles',
      (tester) async {
    final m = MagnifyDrawable(
      const Rect.fromLTWH(20, 20, 60, 40),
      const Offset(200, 160),
      const DrawStyle(),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: CustomPaint(
          size: const Size(320, 320),
          painter: SelectionHighlightPainter(selected: m),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('spotlight layer with a blur effect + feathered holes paints',
      (tester) async {
    const layer = DrawStyle(
      spotlightDim: 60,
      spotlightEffect: SpotlightEffect.blur,
      spotlightFeather: 12,
    );
    final drawables = <Drawable>[
      // A raster region paints UNDER the spotlight layer (part of the photo).
      const BlurDrawable(Rect.fromLTWH(10, 10, 60, 40), style),
      // Two spotlight holes carrying the layer-wide dim / effect / feather.
      const SpotlightDrawable(Rect.fromLTWH(80, 80, 80, 60), layer),
      const SpotlightDrawable(Rect.fromLTWH(180, 120, 60, 60), layer),
      // An annotation paints ABOVE the layer (never dimmed).
      const RectangleDrawable(Rect.fromLTWH(200, 10, 40, 40), style),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: CustomPaint(
          size: const Size(320, 320),
          painter: DrawablePainter(drawables: drawables, spotlightImage: base),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('spotlight layer: dim-only (no effect image), hard edge, paints',
      (tester) async {
    // No effect + feather 0 -> no effect image draw, no mask filter on the hole.
    final drawables = <Drawable>[
      const SpotlightDrawable(Rect.fromLTWH(80, 80, 80, 60),
          DrawStyle(spotlightDim: 50, spotlightFeather: 0)),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: CustomPaint(
          size: const Size(320, 320),
          painter: DrawablePainter(drawables: drawables),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('raster effect with a supplied region image paints (not the '
      'placeholder)', (tester) async {
    final drawables = <Drawable>[
      const BlurDrawable(Rect.fromLTWH(10, 10, 80, 60), style),
      const PixelateDrawable(Rect.fromLTWH(100, 10, 80, 60), style),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: CustomPaint(
          size: const Size(320, 320),
          // Lookup returns a real image -> the drawImageRect path, not the
          // styled placeholder.
          painter: DrawablePainter(
              drawables: drawables, effectImage: (d) => base),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('raster effect placeholder skips the chrome in a tiny region',
      (tester) async {
    // Too small for the watermark icon AND the corner pill -> both are skipped.
    await tester.pumpWidget(
      MaterialApp(
        home: CustomPaint(
          size: const Size(40, 40),
          painter: DrawablePainter(
              drawables: const [BlurDrawable(Rect.fromLTWH(2, 2, 12, 12), style)]),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
