import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/drawable.dart';
import 'package:glimpr/editor/drawable_painter.dart';
import 'package:glimpr/editor/editor_controller.dart';

import '../support/fake_editor_host.dart';

/// The two annotation painters on screen, in paint order (settled, live).
List<DrawablePainter> annotationPainters(WidgetTester tester) => [
      for (final p in tester.widgetList<CustomPaint>(find.byType(CustomPaint)))
        if (p.painter is DrawablePainter) p.painter as DrawablePainter,
    ];

void main() {
  late ui.Image baseImage;
  setUpAll(() async => baseImage = await makeBaseImage(800, 600));
  tearDownAll(() => baseImage.dispose());

  testWidgets('a draw drag paints the preview in the live layer only',
      (tester) async {
    final host = FakeEditorHost(baseImage: baseImage);
    final c = await pumpEditorCore(tester, host);
    c.selectTool(ToolKind.highlighter);
    await tester.pump();

    final g = await tester.startGesture(const Offset(100, 400));
    await g.moveTo(const Offset(260, 480));
    await tester.pump();

    final painters = annotationPainters(tester);
    expect(painters, hasLength(2));
    expect(painters[0].drawables, isEmpty, reason: 'settled: no document yet');
    expect(painters[1].drawables.single, isA<HighlighterDrawable>());

    await g.up();
    await tester.pump();
    final after = annotationPainters(tester);
    expect(after[0].drawables.single, isA<HighlighterDrawable>());
    expect(after[1].drawables, isEmpty, reason: 'committed -> settled layer');
  });

  testWidgets('the settled painter does not repaint across a live drag frame',
      (tester) async {
    final host = FakeEditorHost(baseImage: baseImage);
    final c = await pumpEditorCore(tester, host);
    c.selectTool(ToolKind.line);
    await tester.pump();
    // One committed line, then a second drag in progress.
    var g = await tester.startGesture(const Offset(100, 100));
    await g.moveTo(const Offset(200, 100));
    await tester.pump();
    await g.up();
    await tester.pump();
    g = await tester.startGesture(const Offset(100, 300));
    await g.moveTo(const Offset(150, 300));
    await tester.pump();
    final before = annotationPainters(tester);
    await g.moveTo(const Offset(200, 300));
    await tester.pump();
    final after = annotationPainters(tester);
    expect(after[0].shouldRepaint(before[0]), isFalse,
        reason: 'same committed instances -> settled layer stays cached');
    expect(after[1].shouldRepaint(before[1]), isTrue,
        reason: 'the live preview moved');
    await g.up();
    await tester.pump();
  });

  testWidgets('a spotlight drag joins the settled layer (shared background)',
      (tester) async {
    final host = FakeEditorHost(baseImage: baseImage);
    final c = await pumpEditorCore(tester, host);
    c.selectTool(ToolKind.spotlight);
    await tester.pump();
    final g = await tester.startGesture(const Offset(100, 100));
    await g.moveTo(const Offset(220, 200));
    await tester.pump();
    final painters = annotationPainters(tester);
    expect(painters[0].drawables.single, isA<SpotlightDrawable>());
    expect(painters[1].drawables, isEmpty);
    await g.up();
    await tester.pump();
  });
}
