// GIF encoder benchmark: synthetic screen-recording-like frames pushed
// through the streaming encoder, timing the quantizer sampling pass and the
// per-frame encode work for each option set.
//
//   dart run tool/gif_encode_bench.dart [--frames N] [--width W] [--height H]
//
// Pure Dart on purpose (no Flutter imports) so it runs with plain `dart run`
// on any host the repo builds on. Output size is counted, not written.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:glimpr/gif_editor/encode/gif_encoder.dart';
import 'package:glimpr/gif_editor/encode/palette.dart';

int frames = 300;
int width = 1920;
int height = 1080;

/// Deterministic frame factory: a fixed vertical-gradient desktop, a moving
/// solid "window" with a title bar, and a per-frame pseudo-random content
/// block (stands in for changing text). Regenerated on demand so two passes
/// never hold the whole document in memory.
class FrameFactory {
  FrameFactory() : _bg = Uint8List(width * height * 4) {
    for (var y = 0; y < height; y++) {
      final r = 18 + (y * 30 ~/ height);
      final g = 22 + (y * 40 ~/ height);
      final b = 34 + (y * 60 ~/ height);
      for (var x = 0; x < width; x++) {
        final o = (y * width + x) * 4;
        _bg[o] = r;
        _bg[o + 1] = g;
        _bg[o + 2] = b;
        _bg[o + 3] = 255;
      }
    }
  }

  final Uint8List _bg;

  Uint8List frame(int i) {
    final f = Uint8List.fromList(_bg);
    // Moving window.
    final winW = width ~/ 2, winH = height ~/ 2;
    final wx = (i * 3) % (width - winW);
    final wy = (i * 2) % (height - winH);
    for (var y = wy; y < wy + winH; y++) {
      final base = (y * width + wx) * 4;
      final titleBar = y < wy + 28;
      for (var x = 0; x < winW; x++) {
        final o = base + x * 4;
        if (titleBar) {
          f[o] = 52;
          f[o + 1] = 120;
          f[o + 2] = 246;
        } else {
          f[o] = 238;
          f[o + 1] = 240;
          f[o + 2] = 244;
        }
      }
    }
    // Changing content block inside the window (LCG noise, ~1/6 of it).
    // Clamped to the canvas so tiny smoke-test sizes stay in range.
    var seed = i * 2654435761 & 0x7FFFFFFF;
    final cx = wx + 24, cy = wy + 48;
    final cw = min(winW ~/ 2, max(0, width - cx));
    final ch = winH ~/ 3;
    for (var y = cy; y < min(cy + ch, height); y++) {
      final base = (y * width + cx) * 4;
      for (var x = 0; x < cw; x++) {
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF;
        final v = 190 + (seed & 0x3F);
        final o = base + x * 4;
        f[o] = v;
        f[o + 1] = v;
        f[o + 2] = v;
      }
    }
    return f;
  }
}

void run(String name, GifEncodeOptions options) {
  final factory = FrameFactory();
  final sw = Stopwatch();

  // Generation cost measured (after a JIT warmup) so the sampling figure
  // can subtract it.
  for (var i = 0; i < 3; i++) {
    factory.frame(i);
  }
  sw.start();
  for (var i = 0; i < 5; i++) {
    factory.frame(i);
  }
  sw.stop();
  final genPerFrameMs = sw.elapsedMicroseconds / 5 / 1000;

  Palette? palette;
  var samplingMs = 0.0;
  if (options.strategy == PaletteStrategy.global) {
    final stride = ((width * height * frames) / 2000000).ceil();
    sw
      ..reset()
      ..start();
    Iterable<Uint8List> buffers() sync* {
      for (var i = 0; i < frames; i++) {
        yield factory.frame(i);
      }
    }

    palette = Palette.medianCut(buffers(), sampleStride: stride);
    sw.stop();
    samplingMs = sw.elapsedMilliseconds - genPerFrameMs * frames;
  }

  var bytes = 0;
  final encoder = GifEncoder(
    (chunk) => bytes += chunk.length,
    width: width,
    height: height,
    options: options,
    globalPalette: palette,
  );
  sw.reset();
  var encodeUs = 0;
  for (var i = 0; i < frames; i++) {
    final f = factory.frame(i);
    sw.start();
    encoder.addFrame(f, 33);
    sw.stop();
  }
  sw.start();
  encoder.finish();
  sw.stop();
  encodeUs = sw.elapsedMicroseconds;

  final encodeMs = encodeUs / 1000;
  stdout.writeln('$name: sampling ${samplingMs.round()}ms, '
      'encode ${encodeMs.round()}ms '
      '(${(encodeMs / frames).toStringAsFixed(1)}ms/frame), '
      'total ${(samplingMs + encodeMs).round()}ms, '
      'output ${(bytes / 1024 / 1024).toStringAsFixed(1)}MB');
}

void main(List<String> args) {
  for (var i = 0; i + 1 < args.length; i += 2) {
    final v = int.parse(args[i + 1]);
    switch (args[i]) {
      case '--frames':
        frames = v;
      case '--width':
        width = v;
      case '--height':
        height = v;
    }
  }
  stdout.writeln('gif encode bench: $frames frames at ${width}x$height');
  run('global+optimize        ', const GifEncodeOptions(
      optimizeFrameDiff: true));
  run('global+optimize+dither ', const GifEncodeOptions(
      optimizeFrameDiff: true, dither: true));
  run('global full-frames     ', const GifEncodeOptions());
  run('per-frame+optimize     ', const GifEncodeOptions(
      strategy: PaletteStrategy.perFrame, optimizeFrameDiff: true));
}
