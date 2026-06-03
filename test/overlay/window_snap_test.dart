import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/capture/captured_display.dart';
import 'package:glimpr/overlay/window_snap.dart';

void main() {
  test('returns the topmost (first) window containing the point', () {
    // Front-to-back order: a is in front of b; they overlap at (60,60).
    const a = SnapWindow(
      rect: Rect.fromLTWH(50, 50, 100, 100),
      title: 'A',
      app: 'AppA',
    );
    const b = SnapWindow(
      rect: Rect.fromLTWH(0, 0, 200, 200),
      title: 'B',
      app: 'AppB',
    );
    expect(topmostWindowAt(const [a, b], const Offset(60, 60)), a);
    expect(topmostWindowAt(const [a, b], const Offset(10, 10)), b);
    expect(topmostWindowAt(const [a, b], const Offset(300, 300)), isNull);
    expect(topmostWindowAt(const [], const Offset(60, 60)), isNull);
  });
}
