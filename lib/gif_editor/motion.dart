import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'frame_store.dart';

/// Where the incoming frame enters from during a slide transition.
enum SlideFrom { left, right, top, bottom }

/// Linear blend of two same-size RGBA buffers: `a * (1-t) + b * t`.
Uint8List blendFrames(Uint8List a, Uint8List b, double t) {
  assert(a.length == b.length);
  final out = Uint8List(a.length);
  final ti = (t * 256).round().clamp(0, 256);
  for (var i = 0; i < a.length; i++) {
    out[i] = (a[i] * (256 - ti) + b[i] * ti) >> 8;
  }
  return out;
}

/// Frame [b] covering [a] from a direction: at progress [t] (0..1) the
/// incoming frame has advanced t of the way across the canvas.
Uint8List slideComposite(
    Uint8List a, Uint8List b, int w, int h, double t, SlideFrom from) {
  final out = Uint8List.fromList(a);
  final dx = switch (from) {
    SlideFrom.left => -((1 - t) * w).round(),
    SlideFrom.right => ((1 - t) * w).round(),
    _ => 0,
  };
  final dy = switch (from) {
    SlideFrom.top => -((1 - t) * h).round(),
    SlideFrom.bottom => ((1 - t) * h).round(),
    _ => 0,
  };
  // Blit b offset by (dx, dy) onto out, clipped to the canvas.
  for (var y = 0; y < h; y++) {
    final sy = y - dy;
    if (sy < 0 || sy >= h) continue;
    final x0 = dx > 0 ? dx : 0;
    final x1 = dx > 0 ? w : w + dx;
    if (x1 <= x0) continue;
    out.setRange(
      (y * w + x0) * 4,
      (y * w + x1) * 4,
      b,
      (sy * w + (x0 - dx)) * 4,
    );
  }
  return out;
}

/// Cinemagraph core: keep [frame]'s own pixels INSIDE the rect, take
/// [ref]'s pixels everywhere else.
Uint8List freezeOutside(Uint8List frame, Uint8List ref, int w, int h,
    int rx, int ry, int rw, int rh) {
  final out = Uint8List.fromList(ref);
  final x0 = rx.clamp(0, w);
  final y0 = ry.clamp(0, h);
  final x1 = (rx + rw).clamp(0, w);
  final y1 = (ry + rh).clamp(0, h);
  for (var y = y0; y < y1; y++) {
    out.setRange((y * w + x0) * 4, (y * w + x1) * 4, frame, (y * w + x0) * 4);
  }
  return out;
}

/// Generate [steps] transition frames between the frames at [aPath] and
/// [bPath], writing them to [outPaths] (pre-reserved store paths). Returns
/// the content hashes in order.
Future<List<int>> generateTransition({
  required String aPath,
  required String bPath,
  required List<String> outPaths,
  required int width,
  required int height,
  required bool fade,
  SlideFrom from = SlideFrom.right,
  void Function(int done, int total)? onProgress,
}) async {
  final job = _TransitionJob(
    aPath: aPath,
    bPath: bPath,
    outPaths: outPaths,
    width: width,
    height: height,
    fade: fade,
    from: from,
  );
  return _run(job, onProgress);
}

/// Freeze every frame outside the rect to the reference frame's pixels,
/// writing results to [outPaths] (one per input). Returns content hashes.
Future<List<int>> generateCinemagraph({
  required List<String> framePaths,
  required String refPath,
  required List<String> outPaths,
  required int width,
  required int height,
  required int rx,
  required int ry,
  required int rw,
  required int rh,
  void Function(int done, int total)? onProgress,
}) async {
  final job = _CinemagraphJob(
    framePaths: framePaths,
    refPath: refPath,
    outPaths: outPaths,
    width: width,
    height: height,
    rx: rx,
    ry: ry,
    rw: rw,
    rh: rh,
  );
  return _run(job, onProgress);
}

Future<List<int>> _run(
    Object job, void Function(int done, int total)? onProgress) async {
  final port = ReceivePort();
  final isolate = await Isolate.spawn(_motionEntry, (port.sendPort, job));
  try {
    await for (final msg in port) {
      if (msg is (int, int)) {
        onProgress?.call(msg.$1, msg.$2);
      } else if (msg is List<int>) {
        return msg;
      } else if (msg is String) {
        throw StateError('motion generation failed: $msg');
      }
    }
    throw StateError('motion worker exited without a result');
  } finally {
    port.close();
    isolate.kill(priority: Isolate.immediate);
  }
}

class _TransitionJob {
  const _TransitionJob({
    required this.aPath,
    required this.bPath,
    required this.outPaths,
    required this.width,
    required this.height,
    required this.fade,
    required this.from,
  });

  final String aPath;
  final String bPath;
  final List<String> outPaths;
  final int width;
  final int height;
  final bool fade;
  final SlideFrom from;
}

class _CinemagraphJob {
  const _CinemagraphJob({
    required this.framePaths,
    required this.refPath,
    required this.outPaths,
    required this.width,
    required this.height,
    required this.rx,
    required this.ry,
    required this.rw,
    required this.rh,
  });

  final List<String> framePaths;
  final String refPath;
  final List<String> outPaths;
  final int width;
  final int height;
  final int rx, ry, rw, rh;
}

Future<void> _motionEntry((SendPort, Object) args) async {
  final (send, job) = args;
  try {
    if (job is _TransitionJob) {
      final a = await File(job.aPath).readAsBytes();
      final b = await File(job.bPath).readAsBytes();
      final n = job.outPaths.length;
      final hashes = List<int>.filled(n, 0);
      for (var k = 0; k < n; k++) {
        // t strictly between 0 and 1: the endpoints already exist as the
        // surrounding real frames.
        final t = (k + 1) / (n + 1);
        final out = job.fade
            ? blendFrames(a, b, t)
            : slideComposite(a, b, job.width, job.height, t, job.from);
        hashes[k] = FrameStore.contentHash(out);
        await File(job.outPaths[k]).writeAsBytes(out, flush: false);
        send.send((k + 1, n));
      }
      send.send(hashes);
    } else if (job is _CinemagraphJob) {
      final ref = await File(job.refPath).readAsBytes();
      final n = job.framePaths.length;
      final hashes = List<int>.filled(n, 0);
      for (var i = 0; i < n; i++) {
        final frame = await File(job.framePaths[i]).readAsBytes();
        final out = freezeOutside(frame, ref, job.width, job.height, job.rx,
            job.ry, job.rw, job.rh);
        hashes[i] = FrameStore.contentHash(out);
        await File(job.outPaths[i]).writeAsBytes(out, flush: false);
        send.send((i + 1, n));
      }
      send.send(hashes);
    }
  } catch (e) {
    send.send('$e');
  }
}
