import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/gif_editor/motion.dart';

Uint8List _solid(int w, int h, List<int> rgba) {
  final out = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    out.setRange(i * 4, i * 4 + 4, rgba);
  }
  return out;
}

List<int> _px(Uint8List rgba, int w, int x, int y) =>
    [for (var i = 0; i < 4; i++) rgba[(y * w + x) * 4 + i]];

void main() {
  group('blendFrames', () {
    test('midpoint is the average', () {
      final a = _solid(2, 2, [0, 0, 0, 255]);
      final b = _solid(2, 2, [255, 255, 255, 255]);
      final mid = blendFrames(a, b, 0.5);
      for (var i = 0; i < 4; i++) {
        final p = _px(mid, 2, i % 2, i ~/ 2);
        expect(p[0], inInclusiveRange(126, 129));
        expect(p[3], 255);
      }
    });

    test('endpoints reproduce the sources', () {
      final a = _solid(2, 1, [10, 20, 30, 255]);
      final b = _solid(2, 1, [200, 100, 50, 255]);
      expect(blendFrames(a, b, 0), a);
      expect(blendFrames(a, b, 1), b);
    });
  });

  group('slideComposite', () {
    final a = _solid(4, 2, [0, 0, 0, 255]);
    final b = _solid(4, 2, [255, 255, 255, 255]);

    test('half progress from the right covers the right half', () {
      final out = slideComposite(a, b, 4, 2, 0.5, SlideFrom.right);
      expect(_px(out, 4, 0, 0), [0, 0, 0, 255]); // still a
      expect(_px(out, 4, 1, 0), [0, 0, 0, 255]);
      expect(_px(out, 4, 2, 0), [255, 255, 255, 255]); // b arrived
      expect(_px(out, 4, 3, 1), [255, 255, 255, 255]);
    });

    test('half progress from the left covers the left half', () {
      final out = slideComposite(a, b, 4, 2, 0.5, SlideFrom.left);
      expect(_px(out, 4, 0, 0), [255, 255, 255, 255]);
      expect(_px(out, 4, 1, 0), [255, 255, 255, 255]);
      expect(_px(out, 4, 2, 0), [0, 0, 0, 255]);
    });

    test('half progress from the top covers the top half', () {
      final out = slideComposite(a, b, 4, 2, 0.5, SlideFrom.top);
      expect(_px(out, 4, 0, 0), [255, 255, 255, 255]);
      expect(_px(out, 4, 0, 1), [0, 0, 0, 255]);
    });

    test('full progress is the incoming frame', () {
      expect(slideComposite(a, b, 4, 2, 1, SlideFrom.bottom), b);
    });
  });

  group('freezeOutside', () {
    test('keeps the rect from the frame, everything else from the ref', () {
      final frame = _solid(4, 4, [255, 0, 0, 255]);
      final ref = _solid(4, 4, [0, 0, 255, 255]);
      final out = freezeOutside(frame, ref, 4, 4, 1, 1, 2, 2);
      expect(_px(out, 4, 0, 0), [0, 0, 255, 255]); // frozen (ref)
      expect(_px(out, 4, 1, 1), [255, 0, 0, 255]); // live (frame)
      expect(_px(out, 4, 2, 2), [255, 0, 0, 255]);
      expect(_px(out, 4, 3, 3), [0, 0, 255, 255]);
    });
  });
}
