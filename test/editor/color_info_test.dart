import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/color_info.dart';

void main() {
  group('color_info formatting', () {
    test('hexOf is uppercase RRGGBB with a leading hash', () {
      expect(hexOf(const Color(0xFF5AC8FA)), '#5AC8FA');
      expect(hexOf(const Color(0xFF000000)), '#000000');
      expect(hexOf(const Color(0xFFFFFFFF)), '#FFFFFF');
      expect(hexOf(const Color(0xFF0A0B0C)), '#0A0B0C');
    });

    test('rgbOf lists 8-bit channels', () {
      expect(rgbOf(const Color(0xFF5AC8FA)), '90, 200, 250');
      expect(rgbOf(const Color(0xFF000000)), '0, 0, 0');
    });

    test('hslOf matches CSS conversions', () {
      expect(hslOf(const Color(0xFFFF0000)), '0° 100% 50%');
      expect(hslOf(const Color(0xFF00FF00)), '120° 100% 50%');
      expect(hslOf(const Color(0xFF0000FF)), '240° 100% 50%');
      expect(hslOf(const Color(0xFF808080)), '0° 0% 50%');
      expect(hslOf(const Color(0xFFFFFFFF)), '0° 0% 100%');
      expect(hslOf(const Color(0xFF000000)), '0° 0% 0%');
      expect(hslOf(const Color(0xFF5AC8FA)), '199° 94% 67%');
    });

    test('alpha is ignored (captures are opaque; the tool keeps its own)', () {
      expect(hexOf(const Color(0x805AC8FA)), '#5AC8FA');
      expect(rgbOf(const Color(0x335AC8FA)), '90, 200, 250');
    });

    test('clipboard forms are CSS-ready', () {
      expect(rgbCssOf(const Color(0xFF5AC8FA)), 'rgb(90, 200, 250)');
      expect(hslCssOf(const Color(0xFF5AC8FA)), 'hsl(199, 94%, 67%)');
      expect(hslCssOf(const Color(0xFFFF0000)), 'hsl(0, 100%, 50%)');
    });
  });
}
