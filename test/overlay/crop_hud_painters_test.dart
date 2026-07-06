import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glimpr/overlay/crop_hud.dart';

Future<ui.Image> _solidImage(int w, int h) async {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF446688),
  );
  return rec.endRecording().toImage(w, h);
}

Widget _paintHost(CustomPainter painter) => Directionality(
      textDirection: TextDirection.ltr,
      child: CustomPaint(painter: painter, size: const Size(200, 150)),
    );

void main() {
  late ui.Image base;

  setUpAll(() async {
    base = await _solidImage(64, 48);
  });

  testWidgets('CrosshairPainter paints full lines and the holed variant',
      (tester) async {
    await tester.pumpWidget(_paintHost(const CrosshairPainter(Offset(60, 40))));
    await tester.pumpWidget(
        _paintHost(const CrosshairPainter(Offset(60, 40), hole: 12)));
    expect(tester.takeException(), isNull);
  });

  testWidgets('CrosshairPainter repaints on march ticks', (tester) async {
    final march = ValueNotifier<double>(0);
    addTearDown(march.dispose);
    await tester.pumpWidget(
        _paintHost(CrosshairPainter(const Offset(10, 10), march: march)));
    march.value = 0.5;
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  test('CrosshairPainter shouldRepaint keys on cursor and hole', () {
    const a = CrosshairPainter(Offset(1, 1));
    expect(a.shouldRepaint(const CrosshairPainter(Offset(2, 1))), isTrue);
    expect(
        a.shouldRepaint(const CrosshairPainter(Offset(1, 1), hole: 4)), isTrue);
    expect(a.shouldRepaint(const CrosshairPainter(Offset(1, 1))), isFalse);
  });

  testWidgets('ReticlePainter paints the solid plus', (tester) async {
    await tester.pumpWidget(_paintHost(const ReticlePainter(Offset(30, 30))));
    expect(tester.takeException(), isNull);
    const p = ReticlePainter(Offset(1, 1));
    expect(p.shouldRepaint(const ReticlePainter(Offset(9, 1))), isTrue);
    expect(p.shouldRepaint(const ReticlePainter(Offset(1, 1))), isFalse);
  });

  testWidgets('LoupePainter paints the magnified grid without effects',
      (tester) async {
    await tester.pumpWidget(_paintHost(LoupePainter(
      image: base,
      cursorLogical: const Offset(16, 12),
      scaleFactor: 2,
      logicalSize: const Size(32, 24),
    )));
    expect(tester.takeException(), isNull);
  });

  testWidgets('LoupePainter tolerates a cursor beyond the image edge',
      (tester) async {
    await tester.pumpWidget(_paintHost(LoupePainter(
      image: base,
      cursorLogical: const Offset(-2, -2),
      scaleFactor: 2,
      logicalSize: const Size(32, 24),
      dark: false,
    )));
    expect(tester.takeException(), isNull);
  });

  testWidgets('WindowHighlightPainter outlines the hovered window rect',
      (tester) async {
    final march = ValueNotifier<double>(0);
    addTearDown(march.dispose);
    await tester.pumpWidget(_paintHost(WindowHighlightPainter(
      const Rect.fromLTWH(20, 20, 120, 80),
      march: march,
    )));
    march.value = 0.3;
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('LoupeLevelBlock shows the level text in a HUD pill',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: LoupeLevelBlock(text: 'out 2'))));
    expect(find.text('out 2'), findsOneWidget);
    expect(find.byType(IgnorePointer), findsWidgets);
  });

  testWidgets('LoupeShortcutsBlock lays rows out as a two-column table',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: LoupeShortcutsBlock(rows: [
      (',', 'shrink'),
      ('.', 'grow'),
    ]))));
    expect(find.text(','), findsOneWidget);
    expect(find.text('grow'), findsOneWidget);
    expect(find.byType(Table), findsOneWidget);
  });
}
