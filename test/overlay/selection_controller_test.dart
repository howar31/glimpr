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
}
