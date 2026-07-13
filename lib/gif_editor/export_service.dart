import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'encode/gif_encoder.dart';
import 'encode/palette.dart';
import 'frame_store.dart';
import 'gif_document.dart';

export 'encode/gif_encoder.dart' show PaletteStrategy;

/// User-facing export knobs (the S2 options popover surface). Defaults are
/// the recommended set: one global palette, no dithering, frame-diff
/// optimization on, loop forever.
class GifExportOptions {
  const GifExportOptions({
    this.strategy = PaletteStrategy.global,
    this.dither = false,
    this.optimize = true,
    this.loopCount = 0,
  });

  final PaletteStrategy strategy;
  final bool dither;
  final bool optimize;

  /// GIF semantics: 0 = loop forever.
  final int loopCount;
}

/// Encode [doc] to a GIF file at [outPath] off the UI isolate.
///
/// The worker isolate streams: the global strategy first samples every frame
/// file into the quantizer (progress total counts this as a first pass of
/// frame reads), then frames are read back one at a time and encoded straight
/// into the output sink — no point ever holds the whole document in memory.
/// [options] defaults to the recommended set with the DOCUMENT's loop count.
/// Throws [StateError] if the worker fails; a partial output file is deleted.
Future<void> exportGif({
  required GifDocument doc,
  required FrameStore store,
  required String outPath,
  GifExportOptions? options,
  void Function(int done, int total)? onProgress,
}) async {
  assert(doc.frames.isNotEmpty, 'cannot export an empty document');
  final width = doc.frames.first.width;
  final height = doc.frames.first.height;
  assert(
      doc.frames.every((f) => f.width == width && f.height == height),
      'frames must share one canvas size');
  final opts = options ?? GifExportOptions(loopCount: doc.loopCount);

  final job = _ExportJob(
    framePaths: [for (final f in doc.frames) store.pathFor(f.key)],
    delaysMs: [for (final f in doc.frames) f.delayMs],
    width: width,
    height: height,
    outPath: outPath,
    strategy: opts.strategy,
    dither: opts.dither,
    optimize: opts.optimize,
    loopCount: opts.loopCount,
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
    required this.outPath,
    required this.strategy,
    required this.dither,
    required this.optimize,
    required this.loopCount,
  });

  final List<String> framePaths;
  final List<int> delaysMs;
  final int width;
  final int height;
  final String outPath;
  final PaletteStrategy strategy;
  final bool dither;
  final bool optimize;
  final int loopCount;
}

Future<void> _exportEntry((SendPort, _ExportJob) args) async {
  final (send, job) = args;
  IOSink? sink;
  try {
    final n = job.framePaths.length;
    final global = job.strategy == PaletteStrategy.global;
    final total = global ? n * 2 : n;
    var done = 0;

    Palette? palette;
    if (global) {
      // Sampling pass: the quantizer pulls one frame buffer at a time from
      // this generator, so only a single frame is resident. The stride keeps
      // the histogram work bounded (~2M samples) on big documents.
      final stride =
          ((job.width * job.height * n) / 2000000).ceil().clamp(1, 1 << 20);
      Iterable<Uint8List> buffers() sync* {
        for (final path in job.framePaths) {
          yield File(path).readAsBytesSync();
          send.send((++done, total));
        }
      }

      palette = Palette.medianCut(buffers(), sampleStride: stride);
      done = n;
    }

    sink = File(job.outPath).openWrite();
    final encoder = GifEncoder(
      sink.add,
      width: job.width,
      height: job.height,
      options: GifEncodeOptions(
        strategy: job.strategy,
        dither: job.dither,
        optimizeFrameDiff: job.optimize,
        loopCount: job.loopCount,
      ),
      globalPalette: palette,
    );
    for (var i = 0; i < n; i++) {
      encoder.addFrame(await File(job.framePaths[i]).readAsBytes(), //
          job.delaysMs[i]);
      send.send((++done, total));
    }
    encoder.finish();
    await sink.flush();
    await sink.close();
    sink = null;
    send.send(null);
  } catch (e) {
    try {
      await sink?.close();
    } catch (_) {}
    try {
      File(job.outPath).deleteSync();
    } catch (_) {}
    send.send('$e');
  }
}
