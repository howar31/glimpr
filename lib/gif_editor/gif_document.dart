import 'frame_store.dart';

/// One frame of an animated GIF: which stored pixels it shows and for how
/// long. Frames are immutable; edits produce copies (the undo model snapshots
/// frame lists, so shared instances must never mutate).
class GifFrame {
  const GifFrame({
    required this.key,
    required this.width,
    required this.height,
    required this.delayMs,
  });

  final FrameKey key;
  final int width;
  final int height;
  final int delayMs;

  GifFrame withDelay(int ms) =>
      GifFrame(key: key, width: width, height: height, delayMs: ms);
}

/// The GIF being edited: an ordered frame list plus animation metadata.
class GifDocument {
  const GifDocument({required this.frames, required this.loopCount});

  final List<GifFrame> frames;

  /// GIF NETSCAPE loop count; 0 = loop forever.
  final int loopCount;

  int get frameCount => frames.length;

  Duration get totalDuration => Duration(
      milliseconds: frames.fold(0, (sum, f) => sum + f.delayMs));
}
