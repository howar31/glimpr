import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glimpr/editor/draw_style.dart';
import 'package:glimpr/editor/drawable.dart';
import 'package:glimpr/editor/hdr_plan.dart';
import 'package:glimpr/editor/raster.dart';

Future<ui.Image> _solidImage(int w, int h) async {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );
  return rec.endRecording().toImage(w, h);
}

void main() {
  const style = DrawStyle();
  const logical = ui.Size(16, 12);
  const scale = 2.0;

  test('annotations only produce a single crop-sized overlay segment',
      () async {
    final items = await buildHdrExportItems(
      drawables: const [
        RectangleDrawable(Rect.fromLTWH(2, 2, 4, 4), style),
      ],
      scaleFactor: scale,
      logicalSize: logical,
      selectionLogical: const Rect.fromLTWH(1, 1, 8, 6),
    );
    expect(items, hasLength(1));
    expect(items.single['t'], 'overlay');
    // 8x6 logical crop at 2x = 16x12 native.
    expect(items.single['w'], 16);
    expect(items.single['h'], 12);
    expect(items.single['bytes'], isNotNull);
  });

  test('a blur region flushes the run into overlay/effect/overlay', () async {
    final items = await buildHdrExportItems(
      drawables: const [
        RectangleDrawable(Rect.fromLTWH(1, 1, 3, 3), style),
        BlurDrawable(Rect.fromLTWH(4, 2, 6, 4), style),
        RectangleDrawable(Rect.fromLTWH(8, 8, 2, 2), style),
      ],
      scaleFactor: scale,
      logicalSize: logical,
      selectionLogical: null,
    );
    expect(items.map((i) => i['t']).toList(), ['overlay', 'blur', 'overlay']);
    final blur = items[1];
    // Effect geometry is FRAME-space native px (logical * scale).
    expect(blur['x'], 8.0);
    expect(blur['y'], 4.0);
    expect(blur['w'], 12.0);
    expect(blur['h'], 8.0);
    expect(blur['sigma'], blurSigmaNative(style.strength, scale));
  });

  test('a pixelate region emits its native cell size', () async {
    final items = await buildHdrExportItems(
      drawables: const [
        PixelateDrawable(Rect.fromLTWH(0, 0, 4, 4), style),
      ],
      scaleFactor: scale,
      logicalSize: logical,
      selectionLogical: null,
    );
    expect(items.single['t'], 'pixelate');
    expect(items.single['cell'], pixelateCellNative(style.strength));
  });

  test('a magnify callout splits into under-chrome, content op, over-chrome',
      () async {
    final items = await buildHdrExportItems(
      drawables: const [
        MagnifyDrawable(
            Rect.fromLTWH(2, 2, 4, 3), Offset(10, 8), style),
      ],
      scaleFactor: scale,
      logicalSize: logical,
      selectionLogical: null,
    );
    expect(items.map((i) => i['t']).toList(),
        ['overlay', 'magnify', 'overlay']);
    final mag = items[1];
    expect(mag['sx'], 4.0);
    expect(mag['sy'], 4.0);
    expect(mag['sw'], 8.0);
    expect(mag['sh'], 6.0);
    // Dest geometry scales with the style's magnify factor.
    const src = Rect.fromLTWH(2, 2, 4, 3);
    final dest = Rect.fromCenter(
      center: const Offset(10, 8),
      width: src.width * style.magnifyFactor,
      height: src.height * style.magnifyFactor,
    );
    expect(mag['dx'], dest.left * scale);
    expect(mag['dw'], dest.width * scale);
  });

  test('a spotlight document emits the shared layer with per-hole rects',
      () async {
    final items = await buildHdrExportItems(
      drawables: const [
        RectangleDrawable(Rect.fromLTWH(1, 1, 3, 3), style),
        SpotlightDrawable(Rect.fromLTWH(4, 4, 4, 2), style),
      ],
      scaleFactor: scale,
      logicalSize: logical,
      selectionLogical: null,
    );
    // No raster regions under the layer: spotlight first, ink above it.
    expect(items.map((i) => i['t']).toList(), ['spotlight', 'overlay']);
    final layer = items.first;
    expect(layer['effect'], style.spotlightEffect.name);
    expect(layer['dim'], style.spotlightDim / 100);
    final holes = layer['holes'] as List;
    expect(holes, hasLength(1));
    expect((holes.single as Map)['x'], 8.0);
    expect((holes.single as Map)['w'], 8.0);
  });

  test('blur regions paint under the spotlight layer, ink above', () async {
    final items = await buildHdrExportItems(
      drawables: const [
        RectangleDrawable(Rect.fromLTWH(1, 1, 3, 3), style),
        BlurDrawable(Rect.fromLTWH(0, 0, 2, 2), style),
        SpotlightDrawable(Rect.fromLTWH(4, 4, 4, 2), style),
      ],
      scaleFactor: scale,
      logicalSize: logical,
      selectionLogical: null,
    );
    // Under-run = the blur effect op; then the layer; then the ink overlay.
    expect(items.map((i) => i['t']).toList(),
        ['blur', 'spotlight', 'overlay']);
  });

  test('the cursor layer alone produces an overlay segment', () async {
    final cursor = await _solidImage(4, 4);
    final items = await buildHdrExportItems(
      drawables: const [],
      scaleFactor: scale,
      logicalSize: logical,
      selectionLogical: null,
      cursorImage: cursor,
      cursorTopLeftNative: const ui.Offset(2, 2),
    );
    expect(items.map((i) => i['t']).toList(), ['overlay']);
  });

  test('an empty document yields no items', () async {
    final items = await buildHdrExportItems(
      drawables: const [],
      scaleFactor: scale,
      logicalSize: logical,
      selectionLogical: null,
    );
    expect(items, isEmpty);
  });
}
