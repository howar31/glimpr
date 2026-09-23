import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/overlay/selection_guides.dart';
import 'package:glimpr/overlay/selection_scrim.dart';

import '../support/fake_editor_host.dart';

void main() {
  late ui.Image baseImage;
  setUpAll(() async {
    baseImage = await makeBaseImage(800, 600);
  });

  Finder guides() => find.byWidgetPredicate(
      (w) => w is CustomPaint && w.painter is SelectionGuidesPainter);

  testWidgets('G toggles the guides MID-DRAG when a style is configured',
      (tester) async {
    final host = FakeEditorHost(baseImage: baseImage);
    final c = await pumpEditorCore(tester, host);
    c.guideLines.value = GuideLines.grid;
    c.guideCenter.value = true;
    c.guidesOn.value = false;

    final g = await tester.startGesture(const Offset(100, 100));
    await g.moveTo(const Offset(400, 400));
    await tester.pump();
    expect(guides(), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.pump();
    expect(c.guidesOn.value, isTrue);
    expect(guides(), findsOneWidget);
    final p = tester.widget<CustomPaint>(guides()).painter
        as SelectionGuidesPainter;
    expect(p.lines, GuideLines.grid);
    expect(p.center, isTrue);
    expect(p.rect, const Rect.fromLTRB(100, 100, 401, 401));

    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.pump();
    expect(guides(), findsNothing);
    await g.up();
    await tester.pump();
  });

  testWidgets('guides shown by default appear as soon as the drag starts',
      (tester) async {
    final host = FakeEditorHost(baseImage: baseImage);
    final c = await pumpEditorCore(tester, host);
    c.guideLines.value = GuideLines.diagonals;
    c.guidesOn.value = true;
    final g = await tester.startGesture(const Offset(100, 100));
    await g.moveTo(const Offset(400, 400));
    await tester.pump();
    expect(guides(), findsOneWidget);
    await g.up();
    await tester.pump();
  });

  testWidgets('G is a no-op when nothing is configured (none + no center)',
      (tester) async {
    final host = FakeEditorHost(baseImage: baseImage);
    final c = await pumpEditorCore(tester, host);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyG);
    await tester.pump();
    expect(c.guidesOn.value, isFalse);
    expect(c.hudUserToggled, isFalse);
  });
}
