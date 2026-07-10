import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/composite.dart';

void main() {
  test('whole-display crop = full native size when selection is null', () {
    final r = nativeCropRect(
      selectionLogical: null,
      logicalSize: const Size(100, 50),
      scaleFactor: 2,
    );
    expect(r, const Rect.fromLTWH(0, 0, 200, 100));
  });

  test('logical selection maps to native pixels and clamps to bounds', () {
    final r = nativeCropRect(
      selectionLogical: const Rect.fromLTWH(10, 5, 40, 20),
      logicalSize: const Size(100, 50),
      scaleFactor: 2,
    );
    expect(r, const Rect.fromLTWH(20, 10, 80, 40));
  });

  test('selection exceeding bounds is clamped', () {
    final r = nativeCropRect(
      selectionLogical: const Rect.fromLTWH(80, 40, 50, 50),
      logicalSize: const Size(100, 50),
      scaleFactor: 1,
    );
    expect(r, const Rect.fromLTWH(80, 40, 20, 10));
  });

  test('fractional selection snaps to whole native pixels', () {
    // 150% scale: logical fractions land on fractional native coordinates; the
    // crop must snap to pixel boundaries or the rounded-up last row/column is
    // only partially covered at raster time (semi-transparent edge).
    final r = nativeCropRect(
      selectionLogical: const Rect.fromLTWH(10.2, 5.3, 40.1, 20.4),
      logicalSize: const Size(100, 50),
      scaleFactor: 1.5,
    );
    // Native LTRB 15.3, 7.95, 75.45, 38.55 -> rounded 15, 8, 75, 39.
    expect(r, const Rect.fromLTRB(15, 8, 75, 39));
  });

  test('float-error near-integers snap exactly (n/1.5 logical grid)', () {
    // A 150% display: drag coords are n/1.5 logical; scaling back multiplies
    // the representation error. The crop must come out exactly integral.
    final r = nativeCropRect(
      selectionLogical: const Rect.fromLTWH(
          1160.6666666666667, 796.6666666666666, 158.66666666666652, 567.3333333333334),
      logicalSize: const Size(2560, 1440),
      scaleFactor: 1.5,
    );
    expect(r, const Rect.fromLTRB(1741, 1195, 1979, 2046));
  });
}
