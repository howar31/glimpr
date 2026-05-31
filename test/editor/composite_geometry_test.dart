import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/composite.dart';

void main() {
  test('whole-display crop = full native size when selection is null', () {
    final r = nativeCropRect(
        selectionLogical: null, logicalSize: const Size(100, 50), scaleFactor: 2);
    expect(r, const Rect.fromLTWH(0, 0, 200, 100));
  });

  test('logical selection maps to native pixels and clamps to bounds', () {
    final r = nativeCropRect(
        selectionLogical: const Rect.fromLTWH(10, 5, 40, 20),
        logicalSize: const Size(100, 50),
        scaleFactor: 2);
    expect(r, const Rect.fromLTWH(20, 10, 80, 40));
  });

  test('selection exceeding bounds is clamped', () {
    final r = nativeCropRect(
        selectionLogical: const Rect.fromLTWH(80, 40, 50, 50),
        logicalSize: const Size(100, 50),
        scaleFactor: 1);
    expect(r, const Rect.fromLTWH(80, 40, 20, 10));
  });
}
