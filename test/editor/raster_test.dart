import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/raster.dart';

void main() {
  test('blurSigmaNative scales logical strength by the pixel scale', () {
    expect(blurSigmaNative(12, 2), 24);
    expect(blurSigmaNative(12, 1), 12);
  });

  test('pixelateCellNative is at least 1', () {
    expect(pixelateCellNative(12), 12);
    expect(pixelateCellNative(0.4), 1);
  });

  test('reducedBlurDims shrinks with sigma but stays >= 1', () {
    // sigma 24 -> f = floor(24/2) = 12 -> 240/12 = 20, 120/12 = 10.
    final d = reducedBlurDims(240, 120, 24);
    expect(d.w, 20);
    expect(d.h, 10);
    // A tiny region never goes below 1px.
    expect(reducedBlurDims(2, 2, 40).w, 1);
    // f is at least 1 (no divide-by-zero for a small sigma).
    expect(reducedBlurDims(100, 100, 1).w, 100);
  });

  test('pixelateGridDims is one output px per block, >= 1', () {
    final d = pixelateGridDims(120, 60, 12);
    expect(d.w, 10);
    expect(d.h, 5);
    expect(pixelateGridDims(5, 5, 999).w, 1);
  });
}
