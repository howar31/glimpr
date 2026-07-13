import 'dart:typed_data';
import 'dart:ui' as ui;

import 'frame_store.dart';
import 'gif_document.dart';

/// Decode a GIF into the [store] and build its document.
///
/// Flutter's codec handles GIF frame disposal internally and hands back
/// fully composited frames, so every stored frame is a complete image (the
/// editing model never deals with partial-update frames). Per-frame delays
/// come from [ui.FrameInfo.duration]; a zero delay (common in broken GIFs)
/// normalizes to 100ms, matching mainstream player behavior.
Future<GifDocument> importGif(
  Uint8List gifBytes,
  FrameStore store, {
  void Function(int decoded, int total)? onProgress,
}) async {
  final codec = await ui.instantiateImageCodec(gifBytes);
  try {
    final total = codec.frameCount;
    // Flutter: repetitionCount is -1 for loop-forever; GIF's NETSCAPE value
    // uses 0 for forever, which is what the document model stores.
    final loop = codec.repetitionCount < 0 ? 0 : codec.repetitionCount;
    final frames = <GifFrame>[];
    for (var i = 0; i < total; i++) {
      final info = await codec.getNextFrame();
      final image = info.image;
      try {
        final data =
            await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        final key = await store.put(
            data!.buffer.asUint8List(), image.width, image.height);
        final delay = info.duration.inMilliseconds;
        frames.add(GifFrame(
          key: key,
          width: image.width,
          height: image.height,
          delayMs: delay <= 0 ? 100 : delay,
        ));
      } finally {
        image.dispose();
      }
      onProgress?.call(i + 1, total);
    }
    return GifDocument(frames: frames, loopCount: loop);
  } finally {
    codec.dispose();
  }
}
