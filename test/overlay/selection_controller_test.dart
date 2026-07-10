import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/overlay/selection_controller.dart';

void main() {
  test('begin/update/clear drive the notifier', () {
    final c = SelectionController();
    final seen = <Rect?>[];
    c.rect.addListener(() => seen.add(c.rect.value));

    c.begin(const Offset(10, 10));
    c.update(const Offset(60, 40));
    expect(c.rect.value, const Rect.fromLTRB(10, 10, 60, 40));

    c.clear();
    expect(c.rect.value, isNull);
    expect(seen, isNotEmpty);
  });

  test('normalizes a drag that goes up-left', () {
    final c = SelectionController();
    c.begin(const Offset(60, 40));
    c.update(const Offset(10, 10));
    expect(c.rect.value, const Rect.fromLTRB(10, 10, 60, 40));
  });

  test('aimedSelectionRect includes BOTH endpoints aimed pixels', () {
    // 150% display: cursor positions land on the n/1.5 logical grid. A drag
    // from physical px 400 to physical px 446 must select native [400, 447)
    // — 47 px per axis, both aimed pixels inside.
    const scale = 1.5;
    const a = Offset(400 / scale, 400 / scale);
    const b = Offset(446 / scale, 446 / scale);
    final r = aimedSelectionRect(a, b, scale);
    expect(r.left * scale, closeTo(400, 1e-6));
    expect(r.top * scale, closeTo(400, 1e-6));
    expect(r.right * scale, closeTo(447, 1e-6));
    expect(r.bottom * scale, closeTo(447, 1e-6));
  });

  test('aimedSelectionRect is drag-direction independent', () {
    const scale = 2.0;
    const a = Offset(10.0, 30.0);
    const b = Offset(25.5, 12.5);
    expect(aimedSelectionRect(a, b, scale), aimedSelectionRect(b, a, scale));
  });

  test('a zero-length drag selects exactly one pixel', () {
    final r = aimedSelectionRect(
        const Offset(42, 17), const Offset(42, 17), 1.0);
    expect(r, const Rect.fromLTRB(42, 17, 43, 18));
  });

  test('update routes through the builder; set stays exact', () {
    final c = SelectionController(
      (a, b) => aimedSelectionRect(a, b, 1.0),
    );
    c.begin(const Offset(10, 10));
    c.update(const Offset(20, 15));
    expect(c.rect.value, const Rect.fromLTRB(10, 10, 21, 16));
    // Programmatic rects (handles / move / element snap) pass through as-is.
    c.set(const Rect.fromLTRB(5, 5, 9, 9));
    expect(c.rect.value, const Rect.fromLTRB(5, 5, 9, 9));
    c.dispose();
  });
}
