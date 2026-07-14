import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'frame_store.dart';
import 'gif_document.dart';
import 'transform.dart';

/// Which canvas operation to apply to every frame.
enum CanvasOpKind { crop, resize, flipH, flipV, rotateCw, rotateCcw, rotate180 }

/// A canvas operation plus its parameters (crop rect or resize target).
class CanvasOp {
  const CanvasOp.crop(this.a, this.b, this.c, this.d)
      : kind = CanvasOpKind.crop;
  const CanvasOp.resize(this.a, this.b)
      : kind = CanvasOpKind.resize,
        c = 0,
        d = 0;
  const CanvasOp.flipH()
      : kind = CanvasOpKind.flipH,
        a = 0,
        b = 0,
        c = 0,
        d = 0;
  const CanvasOp.flipV()
      : kind = CanvasOpKind.flipV,
        a = 0,
        b = 0,
        c = 0,
        d = 0;
  const CanvasOp.rotateCw()
      : kind = CanvasOpKind.rotateCw,
        a = 0,
        b = 0,
        c = 0,
        d = 0;
  const CanvasOp.rotateCcw()
      : kind = CanvasOpKind.rotateCcw,
        a = 0,
        b = 0,
        c = 0,
        d = 0;
  const CanvasOp.rotate180()
      : kind = CanvasOpKind.rotate180,
        a = 0,
        b = 0,
        c = 0,
        d = 0;

  final CanvasOpKind kind;

  /// crop: x, y, w, h; resize: target w, h in a/b.
  final int a, b, c, d;

  /// Output canvas size for an input of [w] x [h].
  (int, int) outputSize(int w, int h) => switch (kind) {
        CanvasOpKind.crop => (c, d),
        CanvasOpKind.resize => (a, b),
        CanvasOpKind.rotateCw || CanvasOpKind.rotateCcw => (h, w),
        _ => (w, h),
      };
}

/// Apply [op] to every frame of [doc], writing the results as NEW store
/// entries, and return the replacement frame list (delays preserved).
///
/// The pixel work runs on a worker isolate that reads each frame file and
/// writes the transformed pixels straight to pre-[FrameStore.reserve]d
/// paths — one frame resident at a time, nothing crosses the port but
/// paths and hashes. Throws [StateError] if the worker fails (any files it
/// already wrote are orphaned in the session dir, which dispose cleans up).
Future<List<GifFrame>> transformDocument({
  required GifDocument doc,
  required FrameStore store,
  required CanvasOp op,
  void Function(int done, int total)? onProgress,
}) async {
  assert(doc.frames.isNotEmpty);
  final w = doc.frames.first.width;
  final h = doc.frames.first.height;
  final (ow, oh) = op.outputSize(w, h);
  final keys = [for (final _ in doc.frames) store.reserve()];
  final job = _TransformJob(
    inPaths: [for (final f in doc.frames) store.pathFor(f.key)],
    outPaths: [for (final k in keys) store.pathFor(k)],
    width: w,
    height: h,
    op: op.kind,
    a: op.a,
    b: op.b,
    c: op.c,
    d: op.d,
  );

  final port = ReceivePort();
  final isolate = await Isolate.spawn(_transformEntry, (port.sendPort, job));
  try {
    await for (final msg in port) {
      if (msg is (int, int)) {
        onProgress?.call(msg.$1, msg.$2);
      } else if (msg is List<int>) {
        for (var i = 0; i < keys.length; i++) {
          store.registerHash(keys[i], msg[i]);
        }
        return [
          for (var i = 0; i < keys.length; i++)
            GifFrame(
              key: keys[i],
              width: ow,
              height: oh,
              delayMs: doc.frames[i].delayMs,
            ),
        ];
      } else if (msg is String) {
        throw StateError('transform failed: $msg');
      }
    }
    throw StateError('transform worker exited without a result');
  } finally {
    port.close();
    isolate.kill(priority: Isolate.immediate);
  }
}

class _TransformJob {
  const _TransformJob({
    required this.inPaths,
    required this.outPaths,
    required this.width,
    required this.height,
    required this.op,
    required this.a,
    required this.b,
    required this.c,
    required this.d,
  });

  final List<String> inPaths;
  final List<String> outPaths;
  final int width;
  final int height;
  final CanvasOpKind op;
  final int a, b, c, d;
}

Future<void> _transformEntry((SendPort, _TransformJob) args) async {
  final (send, job) = args;
  try {
    final total = job.inPaths.length;
    final hashes = List<int>.filled(total, 0);
    for (var i = 0; i < total; i++) {
      final src = await File(job.inPaths[i]).readAsBytes();
      final w = job.width, h = job.height;
      final Uint8List out = switch (job.op) {
        CanvasOpKind.crop => cropRect(src, w, h, job.a, job.b, job.c, job.d),
        CanvasOpKind.resize => resizeBilinear(src, w, h, job.a, job.b),
        CanvasOpKind.flipH => flipH(src, w, h),
        CanvasOpKind.flipV => flipV(src, w, h),
        CanvasOpKind.rotateCw => rotate90cw(src, w, h),
        CanvasOpKind.rotateCcw => rotate90ccw(src, w, h),
        CanvasOpKind.rotate180 => rotate180(src, w, h),
      };
      hashes[i] = FrameStore.contentHash(out);
      await File(job.outPaths[i]).writeAsBytes(out, flush: false);
      send.send((i + 1, total));
    }
    send.send(hashes);
  } catch (e) {
    send.send('$e');
  }
}
