import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glimpr/editor/raster.dart';

Future<ui.Image> _solidImage(int w, int h, ui.Color color) async {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = color,
  );
  return rec.endRecording().toImage(w, h);
}

void main() {
  test('blurRegion returns the reduced-resolution region image', () async {
    final frozen = await _solidImage(32, 24, const ui.Color(0xFF808080));
    const region = Rect.fromLTWH(4, 4, 16, 8);
    const sigma = 4.0;
    final out = await blurRegion(frozen, region, sigma);
    final dims = reducedBlurDims(region.width, region.height, sigma);
    expect(out.width, dims.w);
    expect(out.height, dims.h);
  });

  test('blurRegion clamps the inflated source to the frame edge', () async {
    final frozen = await _solidImage(32, 24, const ui.Color(0xFF808080));
    // Region touching the top-left corner: the 3-sigma inflate must clip.
    const region = Rect.fromLTWH(0, 0, 8, 8);
    final out = await blurRegion(frozen, region, 6.0);
    final dims = reducedBlurDims(region.width, region.height, 6.0);
    expect(out.width, dims.w);
    expect(out.height, dims.h);
  });

  test('a blurred solid region stays that color', () async {
    const grey = ui.Color(0xFF808080);
    final frozen = await _solidImage(32, 24, grey);
    final out = await blurRegion(frozen, const Rect.fromLTWH(8, 8, 8, 8), 2.0);
    final data = await out.toByteData(format: ui.ImageByteFormat.rawRgba);
    final r = data!.getUint8(0), g = data.getUint8(1), b = data.getUint8(2);
    // Blurring a uniform field changes nothing (small codec tolerance).
    expect((r - 0x80).abs() <= 1, isTrue, reason: 'r=$r');
    expect((g - 0x80).abs() <= 1, isTrue, reason: 'g=$g');
    expect((b - 0x80).abs() <= 1, isTrue, reason: 'b=$b');
  });

  test('pixelateRegion downsamples to one pixel per cell', () async {
    final frozen = await _solidImage(32, 24, const ui.Color(0xFF204060));
    const region = Rect.fromLTWH(4, 4, 16, 8);
    final out = await pixelateRegion(frozen, region, 4.0);
    final dims = pixelateGridDims(region.width, region.height, 4.0);
    expect(out.width, dims.w);
    expect(out.height, dims.h);
    expect(out.width, 4);
    expect(out.height, 2);
  });

  test('a pixelated solid region keeps the source color', () async {
    const color = ui.Color(0xFF204060);
    final frozen = await _solidImage(32, 24, color);
    final out =
        await pixelateRegion(frozen, const Rect.fromLTWH(0, 0, 8, 8), 4.0);
    final data = await out.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(data!.getUint8(0), 0x20);
    expect(data.getUint8(1), 0x40);
    expect(data.getUint8(2), 0x60);
  });

  test('sub-cell regions still produce a 1x1 grid', () async {
    final frozen = await _solidImage(8, 8, const ui.Color(0xFFFFFFFF));
    final out =
        await pixelateRegion(frozen, const Rect.fromLTWH(0, 0, 2, 2), 12.0);
    expect(out.width, 1);
    expect(out.height, 1);
  });
}
