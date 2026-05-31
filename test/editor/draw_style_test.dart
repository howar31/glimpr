import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/draw_style.dart';

void main() {
  test('default style is red, width 3, font 18', () {
    const s = DrawStyle();
    expect(s.color, const Color(0xFFFF3B30));
    expect(s.strokeWidth, 3);
    expect(s.fontSize, 18);
  });
  test('copyWith overrides only given fields', () {
    const s = DrawStyle();
    final s2 = s.copyWith(color: const Color(0xFF007AFF), strokeWidth: 6);
    expect(s2.color, const Color(0xFF007AFF));
    expect(s2.strokeWidth, 6);
    expect(s2.fontSize, 18);
  });
  test('presets expose the 7 swatch colors', () {
    expect(kColorPresets.length, 7);
    expect(kColorPresets.first, const Color(0xFFFF3B30));
  });
}
