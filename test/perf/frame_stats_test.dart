import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/perf/frame_stats.dart';

void main() {
  group('FrameWindowStats.compute', () {
    test('avg / p90 / worst / jank over a known distribution', () {
      // 10 frames: build 1..10ms, raster 0.5x build, total 2x build.
      final build = [for (var i = 1; i <= 10; i++) i.toDouble()];
      final raster = [for (final b in build) b / 2];
      final total = [for (final b in build) b * 2];
      final s = FrameWindowStats.compute(build, raster, total);
      expect(s.count, 10);
      expect(s.buildAvg, closeTo(5.5, 0.001));
      // Nearest-rank p90 over 10 sorted values -> index 8 (the 9th value).
      expect(s.buildP90, 9.0);
      expect(s.buildWorst, 10.0);
      expect(s.rasterAvg, closeTo(2.75, 0.001));
      expect(s.rasterWorst, 5.0);
      // total = 2,4,...,20 -> 18 and 20 exceed the 17ms default threshold.
      expect(s.jank, 2);
    });

    test('single frame window', () {
      final s = FrameWindowStats.compute([3.0], [1.0], [4.0]);
      expect(s.count, 1);
      expect(s.buildP90, 3.0);
      expect(s.buildWorst, 3.0);
      expect(s.jank, 0);
    });

    test('summary label format', () {
      final s = FrameWindowStats.compute([2.0, 4.0], [1.0, 3.0], [3.0, 18.0]);
      expect(
        s.summary('editor'),
        'frames tag=editor n=2 build=3.0/4.0/4.0 raster=2.0/3.0/3.0 jank=1',
      );
    });

    test('unsorted input is handled (compute sorts internally)', () {
      final s = FrameWindowStats.compute(
        [9.0, 1.0, 5.0],
        [3.0, 2.0, 1.0],
        [10.0, 2.0, 6.0],
      );
      expect(s.buildWorst, 9.0);
      expect(s.rasterWorst, 3.0);
    });
  });

  group('FrameStatsReporter windowing', () {
    test('flushes a full window and starts a fresh one', () {
      final out = <String>[];
      final r = FrameStatsReporter(tag: 't', sink: out.add, windowSize: 3);
      r.addFrame(1, 1, 1);
      r.addFrame(2, 1, 1);
      expect(out, isEmpty);
      r.addFrame(3, 1, 1);
      expect(out, hasLength(1));
      expect(out.single, contains('n=3'));
      expect(out.single, contains('build=2.0/3.0/3.0'));
      // The window restarts empty after the flush.
      r.addFrame(4, 1, 1);
      expect(out, hasLength(1));
    });

    test('manual flush emits a partial window; empty flush is a no-op', () {
      final out = <String>[];
      final r = FrameStatsReporter(tag: 't', sink: out.add, windowSize: 100);
      r.flush();
      expect(out, isEmpty);
      r.addFrame(5, 2, 6);
      r.flush();
      expect(out, hasLength(1));
      expect(out.single, contains('n=1'));
      r.flush();
      expect(out, hasLength(1));
    });
  });
}
