import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

/// The settled annotation layer's repaint boundary (the first DrawablePainter
/// CustomPaint's parent), rasterised as it is on screen.
Future<ui.Image> settledLayerImage(WidgetTester tester) {
  final paint = tester
      .widgetList<CustomPaint>(find.byType(CustomPaint))
      .firstWhere((p) => p.painter is DrawablePainter);
  final ro = tester.renderObject(find.byWidget(paint));
  final boundary = ro.parent! as RenderRepaintBoundary;
  return boundary.toImage();
}

Future<int> pixelAt(ui.Image img, int x, int y) async {
  final bytes = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final i = (y * img.width + x) * 4;
  return (bytes.getUint8(i) << 16) |
      (bytes.getUint8(i + 1) << 8) |
      bytes.getUint8(i + 2);
}

void main() {
  late ui.Image baseImage;
  setUpAll(() async => baseImage = await makeBaseImage(800, 600));
  tearDownAll(() => baseImage.dispose());

  for (final tool in [ToolKind.blur, ToolKind.pixelate]) {
    testWidgets('$tool: the settled layer repaints once the effect image lands',
        (tester) async {
      final host = FakeEditorHost(baseImage: baseImage);
      final c = await pumpEditorCore(tester, host);
      c.selectTool(tool);
      await tester.pump();
      final g = await tester.startGesture(const Offset(50, 50));
      await g.moveTo(const Offset(750, 550));
      await tester.pump();
      // The effect rasterises (toImage) for real inside runAsync; poll for it.
      late DrawablePainter before;
      late Drawable region;
      late int landedPixel;
      await tester.runAsync(() async {
        await g.up();
        await tester.pump();
        before = annotationPainters(tester)[0];
        region = before.drawables.single;
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (before.effectImage!(region) == null &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(before.effectImage!(region), isNotNull, reason: 'image landed');
        await tester.pump();
        await tester.pump();
        landedPixel = await pixelAt(await settledLayerImage(tester), 400, 300);
      });
      // The base image is a flat 0x336699; the placeholder scrim is 0xCC0F1526
      // over it. Once the effect lands the region must show the (blurred /
      // pixelated) base colour, not the scrim.
      expect(landedPixel, 0x336699,
          reason: 'region centre shows the effect, not the placeholder scrim');
    });
  }
}
