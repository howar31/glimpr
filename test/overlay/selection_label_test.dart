import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/overlay/selection_label.dart';

void main() {
  test('formats rounded logical W x H', () {
    expect(selectionLabel(const Rect.fromLTWH(10, 20, 100.4, 50.6)), '100 × 51');
  });
  test('zero-area selection', () {
    expect(selectionLabel(const Rect.fromLTWH(0, 0, 0, 0)), '0 × 0');
  });
}
