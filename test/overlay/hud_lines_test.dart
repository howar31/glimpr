import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/overlay/hud_lines.dart';

void main() {
  // dash 6 / gap 4 -> period 10, unless overridden.
  group('dashOnIntervals', () {
    test('phase 0 lays dashes from the origin, one per period', () {
      final segs = dashOnIntervals(20, dash: 6, gap: 4, phase: 0);
      expect(segs, [(start: 0.0, end: 6.0), (start: 10.0, end: 16.0)]);
    });

    test('clamps the trailing dash to length', () {
      final segs = dashOnIntervals(13, dash: 6, gap: 4, phase: 0);
      expect(segs, [(start: 0.0, end: 6.0), (start: 10.0, end: 13.0)]);
    });

    test('phase shifts the pattern forward (marching ants)', () {
      final segs = dashOnIntervals(20, dash: 6, gap: 4, phase: 5);
      // The dash that began at 0 has crawled to start at 5; a partial dash
      // wraps in at the head.
      expect(segs, [
        (start: 0.0, end: 1.0),
        (start: 5.0, end: 11.0),
        (start: 15.0, end: 20.0),
      ]);
    });

    test('phase one full period is identical to phase 0 (seamless loop)', () {
      final a = dashOnIntervals(20, dash: 6, gap: 4, phase: 0);
      final b = dashOnIntervals(20, dash: 6, gap: 4, phase: 10);
      expect(b, a);
    });

    test('negative / non-zero remainder phase is normalized', () {
      final a = dashOnIntervals(20, dash: 6, gap: 4, phase: 5);
      final b = dashOnIntervals(20, dash: 6, gap: 4, phase: -5);
      expect(b, a);
    });

    test('degenerate inputs yield nothing', () {
      expect(dashOnIntervals(0, dash: 6, gap: 4), isEmpty);
      expect(dashOnIntervals(20, dash: 0, gap: 4), isEmpty);
    });

    test('default pattern matches the shared HUD constants', () {
      final segs = dashOnIntervals(kHudDashPeriod * 2);
      expect(segs.first, (start: 0.0, end: kHudDash));
      expect(segs[1].start, kHudDashPeriod);
    });
  });

  group('addDashedLinePoints', () {
    test('emits one point pair (4 floats) per dash, along the segment', () {
      final out = <double>[];
      // Horizontal segment of length 20: dashes (0,6) and (10,16) at phase 0.
      addDashedLinePoints(
        out,
        const Offset(0, 5),
        const Offset(20, 5),
        dash: 6,
        gap: 4,
        phase: 0,
      );
      expect(out, [0, 5, 6, 5, 10, 5, 16, 5]);
    });

    test('zero-length segment emits nothing', () {
      final out = <double>[];
      addDashedLinePoints(out, const Offset(3, 3), const Offset(3, 3));
      expect(out, isEmpty);
    });
  });

  group('roundedRectPolyline', () {
    test('zero radius -> the four sharp corners', () {
      final pts = roundedRectPolyline(const Rect.fromLTWH(0, 0, 100, 80), 0);
      expect(pts, [
        const Offset(0, 0),
        const Offset(100, 0),
        const Offset(100, 80),
        const Offset(0, 80),
      ]);
    });

    test('rounded -> 4 corners x (cornerSteps + 1) points, inside the rect', () {
      const rect = Rect.fromLTWH(0, 0, 100, 80);
      final pts = roundedRectPolyline(rect, 10, cornerSteps: 4);
      expect(pts.length, 4 * 5);
      for (final p in pts) {
        expect(rect.inflate(0.01).contains(p), isTrue);
      }
    });
  });
}
