import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/overlay/selection_scrim.dart';

void main() {
  const size = Size(400, 300);

  test('no selection -> scrim covers the whole canvas', () {
    final path = scrimPath(size, null);
    expect(path.contains(const Offset(200, 150)), isTrue); // center covered
  });

  test('with selection -> hole is clear, outside is covered', () {
    final sel = const Rect.fromLTWH(
      100,
      50,
      100,
      80,
    ); // hole 100..200 x 50..130
    final path = scrimPath(size, sel);
    expect(
      path.contains(const Offset(150, 90)),
      isFalse,
    ); // inside hole -> not scrim
    expect(path.contains(const Offset(10, 10)), isTrue); // outside -> scrim
  });

  test('selection clamped to canvas bounds', () {
    final sel = const Rect.fromLTWH(
      -50,
      -50,
      100,
      100,
    ); // hole 0..50 x 0..50 after clamp
    final path = scrimPath(size, sel);
    expect(path.contains(const Offset(25, 25)), isFalse); // inside clamped hole
    expect(path.contains(const Offset(300, 200)), isTrue); // outside
  });
}
