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

/// Captures LoupePainter's drawImageRect geometry (all other canvas calls are
/// no-ops) so the sampled source rect is assertable without rasterizing.
class _RecordingCanvas implements Canvas {
  Rect? imageSrc;
  Rect? imageDst;

  @override
  void drawImageRect(ui.Image image, Rect src, Rect dst, Paint paint) {
    imageSrc = src;
    imageDst = dst;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  late ui.Image base;

  setUpAll(() async {
    base = await _solidImage(64, 48);
  });

  test('liveLoupeCenter lands the painter snap on the aimed patch cell', () {
    // The native live feeds center the span×span patch on the aimed pixel at
    // cell index span ~/ 2. LoupePainter snaps its view to
    // (centerPx - 0.5).round() + 0.5; that snap must land exactly on the
    // aimed cell's pixel center or the loupe shows the WRONG center pixel and
    // an out-of-patch black edge on the right/bottom.
    for (final span in [5, 7, 9, 11, 13, 15, 17, 19, 21]) {
      for (final scale in [1.0, 1.25, 1.5, 2.0]) {
        final c = liveLoupeCenter(span, scale);
        final centerPx = c.dx * scale;
        final snapped = (centerPx - 0.5).roundToDouble() + 0.5;
        expect(snapped, span ~/ 2 + 0.5, reason: 'span=$span scale=$scale');
      }
    }
  });

  test('live loupe samples exactly the whole patch, aim on the center cell',
      () async {
    // End-to-end painter geometry for the LIVE record-select loupe: with the
    // patch-center aim from liveLoupeCenter, the painted source rect must be
    // EXACTLY the span×span patch — no out-of-patch overhang (the black-edge
    // bug) and the aimed pixel dead-center.
    const span = 13;
    const scale = 1.5;
    final patch = await _solidImage(span, span);
    final canvas = _RecordingCanvas();
    LoupePainter(
      image: patch,
      cursorLogical: liveLoupeCenter(span, scale),
      scaleFactor: scale,
      zoom: 8,
    ).paint(canvas, const Size(span * 8.0, span * 8.0));
    expect(canvas.imageSrc, const Rect.fromLTRB(0, 0, 13, 13));
    expect(canvas.imageDst, const Rect.fromLTRB(0, 0, 104, 104));
  });

  test('frozen loupe centers the sampled rect on the aimed pixel', () {
    // Screenshot (frozen) path: the painter receives the RAW cursor and must
    // snap its sampled rect onto the same aimed pixel the readout names
    // (round(x*scale - 0.5)) — center cell == aimed pixel == readout, the
    // same guarantee the live test above pins for record-select.
    const scale = 2.0;
    const cursor = Offset(10.4, 7.2);
    final canvas = _RecordingCanvas();
    LoupePainter(
      image: base, // 64x48 native px
      cursorLogical: cursor,
      scaleFactor: scale,
      zoom: 8,
    ).paint(canvas, const Size(104, 104)); // 13 native px across
    final aimedX = (cursor.dx * scale - 0.5).round(); // 20 — the readout pixel
    final aimedY = (cursor.dy * scale - 0.5).round(); // 14
    expect(
      canvas.imageSrc,
      Rect.fromCenter(
        center: Offset(aimedX + 0.5, aimedY + 0.5),
        width: 13,
        height: 13,
      ),
    );
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
