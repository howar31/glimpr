import 'dart:typed_data';

import 'gif_encoder.dart';
import 'palette.dart';

/// One frame handed to the writer: full-size RGBA pixels + its delay.
class FrameSpec {
  const FrameSpec(this.rgba, this.delayMs);

  final Uint8List rgba;
  final int delayMs;
}

/// Encode full-size RGBA frames into a GIF89a byte stream, in memory.
///
/// A convenience wrapper over the streaming [GifEncoder] for callers (and
/// tests) whose frames already sit in memory. Defaults preserve the S1
/// behavior: full-canvas frames with disposal "restore to background", a
/// single global palette (median-cut over all frames unless [palette] is
/// given), no dithering, no frame-diff optimization. [loopCount] uses GIF
/// semantics: 0 = forever.
Uint8List encodeGifFrames({
  required List<FrameSpec> frames,
  required int width,
  required int height,
  required int loopCount,
  Palette? palette,
  PaletteStrategy strategy = PaletteStrategy.global,
  bool dither = false,
  bool optimize = false,
}) {
  assert(frames.isNotEmpty, 'cannot encode an empty GIF');
  final options = GifEncodeOptions(
    strategy: strategy,
    dither: dither,
    optimizeFrameDiff: optimize,
    loopCount: loopCount,
  );
  final global = strategy == PaletteStrategy.global
      ? (palette ?? Palette.medianCut([for (final f in frames) f.rgba]))
      : null;
  final out = BytesBuilder(copy: false);
  final encoder = GifEncoder(
    out.add,
    width: width,
    height: height,
    options: options,
    globalPalette: global,
  );
  for (final frame in frames) {
    assert(frame.rgba.length == width * height * 4,
        'frame pixels must be width*height*4');
    encoder.addFrame(frame.rgba, frame.delayMs);
  }
  encoder.finish();
  return out.takeBytes();
}
