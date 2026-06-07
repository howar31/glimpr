import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/curve.dart';
import 'package:glimpr/editor/draw_style.dart';

void main() {
  group('sampleCatmullRom', () {
    test('two points -> the two points', () {
      final s = sampleCatmullRom([const Offset(0, 0), const Offset(10, 0)]);
      expect(s, [const Offset(0, 0), const Offset(10, 0)]);
    });

    test('passes through every control point', () {
      final pts = [
        const Offset(0, 0),
        const Offset(5, 8),
        const Offset(10, 0),
      ];
      final s = sampleCatmullRom(pts, perSegment: 8);
      for (final p in pts) {
        expect(
          s.any((q) => (q - p).distance < 0.001),
          isTrue,
          reason: 'sample should contain control point $p',
        );
      }
    });

    test('collinear control points stay on the line', () {
      final s = sampleCatmullRom([
        const Offset(0, 0),
        const Offset(5, 0),
        const Offset(10, 0),
      ], perSegment: 6);
      for (final p in s) {
        expect(p.dy.abs() < 0.001, isTrue);
      }
    });
  });

  group('curveTangent', () {
    test('straight horizontal: outward at each end', () {
      final pts = [const Offset(0, 0), const Offset(10, 0)];
      final end = curveTangent(pts, atEnd: true);
      final start = curveTangent(pts, atEnd: false);
      expect((end - const Offset(1, 0)).distance < 0.001, isTrue);
      expect((start - const Offset(-1, 0)).distance < 0.001, isTrue);
    });
  });

  group('seedInterior', () {
    test('one interior point = the midpoint', () {
      final p = seedInterior(const Offset(0, 0), const Offset(10, 0), 1);
      expect(p, [const Offset(0, 0), const Offset(5, 0), const Offset(10, 0)]);
    });

    test('two interior points evenly split the span', () {
      final p = seedInterior(const Offset(0, 0), const Offset(9, 0), 2);
      expect(p.length, 4);
      expect(p.first, const Offset(0, 0));
      expect(p.last, const Offset(9, 0));
      expect((p[1] - const Offset(3, 0)).distance < 0.001, isTrue);
      expect((p[2] - const Offset(6, 0)).distance < 0.001, isTrue);
    });
  });

  group('resampleInterior', () {
    test('keeps endpoints and the requested interior count', () {
      final out = resampleInterior([
        const Offset(0, 0),
        const Offset(5, 6),
        const Offset(10, 0),
      ], 3);
      expect(out.length, 5); // start + 3 interior + end
      expect(out.first, const Offset(0, 0));
      expect(out.last, const Offset(10, 0));
    });

    test('straight line stays straight after resample', () {
      final out =
          resampleInterior([const Offset(0, 0), const Offset(10, 0)], 1);
      expect(out.length, 3);
      expect(out[1].dy.abs() < 0.001, isTrue);
    });
  });

  group('dashPattern', () {
    test('solid is empty', () {
      expect(dashPattern(LineStyle.solid, 4), isEmpty);
    });

    test('dashed scales with stroke width', () {
      expect(dashPattern(LineStyle.dashed, 4), [
        (len: 16.0, kind: DashKind.dash),
        (len: 12.0, kind: DashKind.gap),
      ]);
    });

    test('dotted leads with a dot run', () {
      final p = dashPattern(LineStyle.dotted, 3);
      expect(p.first.kind, DashKind.dot);
      expect(p.first.len, 3.0);
    });

    test('dash-dot has dash + dot runs', () {
      final p = dashPattern(LineStyle.dashDot, 2);
      expect(p.where((r) => r.kind == DashKind.dash).length, 1);
      expect(p.where((r) => r.kind == DashKind.dot).length, 1);
    });

    test('dash-dot-dot has two dots', () {
      final p = dashPattern(LineStyle.dashDotDot, 2);
      expect(p.where((r) => r.kind == DashKind.dot).length, 2);
    });
  });

  group('pen smoothing', () {
    test('kPenSmoothMinDist is a positive spacing', () {
      expect(kPenSmoothMinDist, greaterThan(0));
    });

    test('decimateByDistance drops near points and keeps the endpoints', () {
      final pts = [
        const Offset(0, 0),
        const Offset(1, 0), // 1px from the kept (0,0) -> dropped
        const Offset(2, 0), // still < 5px -> dropped
        const Offset(10, 0), // 10px from (0,0) -> kept
        const Offset(11, 0), // close to (10,0) but it's the LAST -> kept
      ];
      expect(decimateByDistance(pts, 5), [
        const Offset(0, 0),
        const Offset(10, 0),
        const Offset(11, 0),
      ]);
    });

    test('decimateByDistance with minDist<=0 is the identity', () {
      final pts = [const Offset(0, 0), const Offset(1, 0), const Offset(2, 0)];
      expect(decimateByDistance(pts, 0), pts);
      expect(decimateByDistance(pts, -5), pts);
    });

    test('decimateByDistance leaves 2-or-fewer points unchanged', () {
      final two = [const Offset(0, 0), const Offset(1, 0)];
      expect(decimateByDistance(two, 100), two);
    });

    test('decimateByDistance thins a dense jittery stroke, keeps endpoints', () {
      final pts = [
        for (var i = 0; i < 50; i++)
          Offset(i.toDouble(), (i % 2).toDouble()), // a jittery dense stroke
      ];
      final out = decimateByDistance(pts, kPenSmoothMinDist);
      expect(out.length, lessThan(pts.length));
      expect(out.first, pts.first);
      expect(out.last, pts.last);
    });
  });
}
