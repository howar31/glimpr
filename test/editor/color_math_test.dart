import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/color_math.dart';

void main() {
  test('hexToColor parses #RRGGBB as opaque', () {
    expect(hexToColor('#FF3B30'), const Color(0xFFFF3B30));
    expect(hexToColor('00AAff'), const Color(0xFF00AAFF)); // no #, lowercase
  });

  test('hexToColor parses #AARRGGBB with alpha', () {
    expect(hexToColor('#8012AB34'), const Color(0x8012AB34));
  });

  test('hexToColor rejects invalid input', () {
    expect(hexToColor('#12'), isNull);
    expect(hexToColor('zzzzzz'), isNull);
    expect(hexToColor(''), isNull);
  });

  test('colorToHex formats with and without alpha', () {
    expect(colorToHex(const Color(0xFFFF3B30), withAlpha: false), '#FF3B30');
    expect(colorToHex(const Color(0x8012AB34)), '#8012AB34');
  });

  test('pushRecentColor is MRU, deduped, capped', () {
    var r = <int>[];
    r = pushRecentColor(r, 0x111111, cap: 3);
    r = pushRecentColor(r, 0x222222, cap: 3);
    r = pushRecentColor(r, 0x111111, cap: 3); // re-push moves to front
    expect(r, [0x111111, 0x222222]);
    r = pushRecentColor(r, 0x333333, cap: 3);
    r = pushRecentColor(r, 0x444444, cap: 3); // exceeds cap -> drops oldest
    expect(r.length, 3);
    expect(r.first, 0x444444);
    expect(r.contains(0x222222), isFalse);
  });
}
