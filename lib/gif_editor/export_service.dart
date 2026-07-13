import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'encode/gif_writer.dart';
import 'frame_store.dart';
import 'gif_document.dart';

/// Encode [doc] to a GIF file at [outPath] off the UI isolate.
///
/// The worker isolate reads the raw RGBA frame files straight from the
/// [FrameStore] paths (no pixel shuttling over ports) and reports progress
/// once per frame consumed. Throws [StateError] if the worker fails.
Future<void> exportGif({
  required GifDocument doc,
  required FrameStore store,
  required String outPath,
  void Function(int done, int total)? onProgress,
}) async {
  assert(doc.frames.isNotEmpty, 'cannot export an empty document');
  final width = doc.frames.first.width;
  final height = doc.frames.first.height;
  assert(
      doc.frames.every((f) => f.width == width && f.height == height),
      'frames must share one canvas size');

  final job = _ExportJob(
    framePaths: [for (final f in doc.frames) store.pathFor(f.key)],
    delaysMs: [for (final f in doc.frames) f.delayMs],
    width: width,
    height: height,
    loopCount: doc.loopCount,
    outPath: outPath,
  );

  final port = ReceivePort();
  final isolate = await Isolate.spawn(_exportEntry, (port.sendPort, job));
  try {
    await for (final msg in port) {
      if (msg is (int, int)) {
        onProgress?.call(msg.$1, msg.$2);
      } else if (msg == null) {
        return; // done
      } else if (msg is String) {
        throw StateError('GIF export failed: $msg');
      }
    }
  } finally {
    port.close();
    isolate.kill(priority: Isolate.immediate);
  }
}

class _ExportJob {
  const _ExportJob({
    required this.framePaths,
    required this.delaysMs,
    required this.width,
    required this.height,
    required this.loopCount,
    required this.outPath,
  });

  final List<String> framePaths;
  final List<int> delaysMs;
  final int width;
  final int height;
  final int loopCount;
  final String outPath;
}

Future<void> _exportEntry((SendPort, _ExportJob) args) async {
  final (send, job) = args;
  try {
    final total = job.framePaths.length;
    final frames = <FrameSpec>[];
    for (var i = 0; i < total; i++) {
      final rgba = await File(job.framePaths[i]).readAsBytes();
      frames.add(FrameSpec(Uint8List.fromList(rgba), job.delaysMs[i]));
      send.send((i + 1, total));
    }
    final bytes = encodeGifFrames(
      frames: frames,
      width: job.width,
      height: job.height,
      loopCount: job.loopCount,
    );
    await File(job.outPath).writeAsBytes(bytes, flush: true);
    send.send(null);
  } catch (e) {
    send.send('$e');
  }
}
