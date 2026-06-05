import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/viewport.dart';

void main() {
  group('EditorViewport', () {
    // Helper: compare Offsets within epsilon.
    void expectClose(Offset a, Offset b, [double eps = 1e-9]) {
      expect(a.dx, closeTo(b.dx, eps));
      expect(a.dy, closeTo(b.dy, eps));
    }

    group('identity', () {
      test('toLogical(p) == p', () {
        const vp = EditorViewport.identity;
        const p = Offset(123.4, 56.7);
        expect(vp.toLogical(p), p);
      });

      test('toLocal(p) == p', () {
        const vp = EditorViewport.identity;
        const p = Offset(0.5, 999.0);
        expect(vp.toLocal(p), p);
      });
    });

    group('round-trip', () {
      final cases = [
        (scale: 2.0, offset: const Offset(50.0, 30.0)),
        (scale: 0.5, offset: const Offset(-10.0, 20.0)),
        (scale: 3.75, offset: const Offset(0.0, -100.0)),
        (scale: 1.0, offset: const Offset(200.0, 0.0)),
      ];
      final points = [
        const Offset(0.0, 0.0),
        const Offset(100.0, 200.0),
        const Offset(-50.0, 73.5),
      ];

      for (final c in cases) {
        for (final p in points) {
          test('scale=${c.scale} offset=${c.offset} point=$p', () {
            final vp = EditorViewport(scale: c.scale, offset: c.offset);
            expectClose(vp.toLogical(vp.toLocal(p)), p);
            expectClose(vp.toLocal(vp.toLogical(p)), p);
          });
        }
      }
    });

    group('zoomedAround', () {
      test('logical point under anchor is unchanged', () {
        const vp = EditorViewport(scale: 1.0, offset: Offset(10.0, 20.0));
        const anchor = Offset(150.0, 100.0);
        final zoomed = vp.zoomedAround(anchor, 2.5);
        expectClose(zoomed.toLogical(anchor), vp.toLogical(anchor));
      });

      test('new scale is applied', () {
        const vp = EditorViewport.identity;
        final zoomed = vp.zoomedAround(const Offset(50.0, 50.0), 3.0);
        expect(zoomed.scale, closeTo(3.0, 1e-9));
      });

      test('anchored at origin keeps offset zero', () {
        const vp = EditorViewport.identity;
        final zoomed = vp.zoomedAround(Offset.zero, 2.0);
        expectClose(zoomed.offset, Offset.zero);
      });
    });

    group('fit', () {
      test('landscape image fits by width', () {
        // 4000x3000 into 900x900: limiting dim is width, scale=900/4000
        final vp = EditorViewport.fit(const Size(4000, 3000), const Size(900, 900));
        expect(vp.scale, closeTo(900 / 4000, 1e-9));
      });

      test('landscape image is centred vertically', () {
        final vp = EditorViewport.fit(const Size(4000, 3000), const Size(900, 900));
        // scaled height = 3000 * (900/4000) = 675; vertical margin = (900-675)/2 = 112.5
        expect(vp.offset.dx, closeTo(0.0, 1e-9));
        expect(vp.offset.dy, greaterThan(0.0));
        expect(vp.offset.dy, closeTo((900 - 3000 * (900 / 4000)) / 2, 1e-9));
      });

      test('never upscales past maxScale=1.0', () {
        final vp = EditorViewport.fit(const Size(100, 100), const Size(900, 900));
        expect(vp.scale, closeTo(1.0, 1e-9));
      });

      test('never upscales with custom maxScale', () {
        final vp = EditorViewport.fit(
          const Size(100, 100),
          const Size(900, 900),
          maxScale: 2.0,
        );
        expect(vp.scale, closeTo(2.0, 1e-9));
      });

      test('zero-size logical returns identity', () {
        final vp = EditorViewport.fit(const Size(0, 0), const Size(900, 900));
        expect(vp.scale, closeTo(1.0, 1e-9));
        expect(vp.offset, Offset.zero);
      });
    });

    group('pannedBy', () {
      test('offset adds, scale unchanged', () {
        const vp = EditorViewport(scale: 2.0, offset: Offset(10.0, 20.0));
        final panned = vp.pannedBy(const Offset(5.0, -3.0));
        expect(panned.scale, closeTo(2.0, 1e-9));
        expectClose(panned.offset, const Offset(15.0, 17.0));
      });

      test('zero delta is no-op', () {
        const vp = EditorViewport(scale: 1.5, offset: Offset(100.0, 50.0));
        final panned = vp.pannedBy(Offset.zero);
        expect(panned.scale, closeTo(vp.scale, 1e-9));
        expectClose(panned.offset, vp.offset);
      });
    });
  });
}
