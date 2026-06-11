import 'dart:async';
import 'package:flutter/scheduler.dart';

/// Aggregated render statistics for one window of frames, emitted to the
/// unified-log perf marks (see PerfLog on the native side). One summary line
/// per [FrameStatsReporter.windowSize] frames — or per interaction, whichever
/// ends first — so a release build can report interactive frame cost without
/// DevTools attached.
class FrameWindowStats {
  const FrameWindowStats({
    required this.count,
    required this.buildAvg,
    required this.buildP90,
    required this.buildWorst,
    required this.rasterAvg,
    required this.rasterP90,
    required this.rasterWorst,
    required this.jank,
  });

  final int count;
  final double buildAvg, buildP90, buildWorst;
  final double rasterAvg, rasterP90, rasterWorst;

  /// Frames whose total span exceeded the jank threshold (default = one 60Hz
  /// frame budget; a ProMotion display still treats 17ms as "user-visible").
  final int jank;

  /// All lists must be the same length and non-empty.
  static FrameWindowStats compute(
    List<double> buildMs,
    List<double> rasterMs,
    List<double> totalMs, {
    double jankThresholdMs = 17.0,
  }) {
    assert(buildMs.isNotEmpty);
    assert(buildMs.length == rasterMs.length &&
        buildMs.length == totalMs.length);
    final b = List.of(buildMs)..sort();
    final r = List.of(rasterMs)..sort();
    return FrameWindowStats(
      count: buildMs.length,
      buildAvg: _avg(buildMs),
      buildP90: _percentile(b, 90),
      buildWorst: b.last,
      rasterAvg: _avg(rasterMs),
      rasterP90: _percentile(r, 90),
      rasterWorst: r.last,
      jank: totalMs.where((t) => t > jankThresholdMs).length,
    );
  }

  static double _avg(List<double> v) =>
      v.reduce((a, b) => a + b) / v.length;

  /// Nearest-rank percentile over an already-sorted list.
  static double _percentile(List<double> sorted, int p) =>
      sorted[((p / 100) * (sorted.length - 1)).round()];

  String _f(double v) => v.toStringAsFixed(1);

  /// Compact mark label: values are avg/p90/worst in ms.
  String summary(String tag) => 'frames tag=$tag n=$count '
      'build=${_f(buildAvg)}/${_f(buildP90)}/${_f(buildWorst)} '
      'raster=${_f(rasterAvg)}/${_f(rasterP90)}/${_f(rasterWorst)} '
      'jank=$jank';
}

/// Accumulates [FrameTiming]s (release-mode safe) and pushes a
/// [FrameWindowStats.summary] to [sink] every [windowSize] frames; a partial
/// window is flushed [idleFlushMs] after frames stop, so each interaction gets
/// its own summary instead of bleeding into the next one. Engines only render
/// when something changes, so this is silent at idle.
class FrameStatsReporter {
  FrameStatsReporter({
    required this.tag,
    required this.sink,
    this.windowSize = 120,
    this.idleFlushMs = 1000,
  });

  final String tag;
  final void Function(String label) sink;
  final int windowSize;
  final int idleFlushMs;

  final List<double> _build = [], _raster = [], _total = [];
  TimingsCallback? _cb;
  Timer? _idleFlush;

  void attach() {
    if (_cb != null) return;
    _cb = _onTimings;
    SchedulerBinding.instance.addTimingsCallback(_cb!);
  }

  void detach() {
    if (_cb != null) SchedulerBinding.instance.removeTimingsCallback(_cb!);
    _cb = null;
    _idleFlush?.cancel();
    _idleFlush = null;
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      addFrame(
        t.buildDuration.inMicroseconds / 1000.0,
        t.rasterDuration.inMicroseconds / 1000.0,
        t.totalSpan.inMicroseconds / 1000.0,
      );
    }
    _idleFlush?.cancel();
    _idleFlush = Timer(Duration(milliseconds: idleFlushMs), flush);
  }

  /// Visible for tests (FrameTiming is awkward to construct directly).
  void addFrame(double buildMs, double rasterMs, double totalMs) {
    _build.add(buildMs);
    _raster.add(rasterMs);
    _total.add(totalMs);
    if (_build.length >= windowSize) flush();
  }

  void flush() {
    if (_build.isEmpty) return;
    final stats = FrameWindowStats.compute(_build, _raster, _total);
    _build.clear();
    _raster.clear();
    _total.clear();
    sink(stats.summary(tag));
  }
}
