import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

/// Opaque identity of one stored frame. Value semantics so documents and
/// undo mementos can reference frames cheaply.
class FrameKey {
  const FrameKey(this.value);

  final int value;

  @override
  bool operator ==(Object other) => other is FrameKey && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'FrameKey($value)';
}

/// Disk-backed storage for decoded GIF frames.
///
/// A GIF can carry hundreds of frames; keeping them all decoded in memory is
/// not an option (300 frames of 1080p RGBA is ~2.4GB). Frames therefore live
/// as raw RGBA files in a session temp directory and only a small LRU window
/// of decoded [ui.Image]s stays warm for the preview and the filmstrip.
///
/// Deleted frames are NOT removed from disk until [dispose]: undo mementos
/// hold [FrameKey]s, so any frame ever stored must stay readable for the
/// session's lifetime.
class FrameStore {
  FrameStore(this.dir);

  /// Decoded-image LRU capacity. Sized for the preview plus a screenful of
  /// filmstrip thumbnails.
  static const int imageCacheCap = 24;

  final Directory dir;

  int _nextKey = 0;
  final LinkedHashMap<FrameKey, ui.Image> _images =
      LinkedHashMap<FrameKey, ui.Image>();

  /// Persist one frame of raw RGBA pixels; returns its key.
  Future<FrameKey> put(Uint8List rgba, int width, int height) async {
    assert(rgba.length == width * height * 4,
        'rgba length must be width*height*4');
    final key = FrameKey(_nextKey++);
    await File(pathFor(key)).writeAsBytes(rgba, flush: false);
    return key;
  }

  /// Absolute path of the raw RGBA file for [key]. The export isolate reads
  /// these files directly instead of shuttling pixels over ports.
  String pathFor(FrameKey key) => '${dir.path}/f${key.value}.rgba';

  /// Decoded image for [key], LRU-cached. [width]/[height] must match the
  /// dimensions the frame was stored with (the store keeps no header; the
  /// document model owns per-frame dimensions).
  Future<ui.Image> image(FrameKey key, int width, int height) async {
    final cached = _images.remove(key);
    if (cached != null) {
      _images[key] = cached; // re-insert = most recently used
      return cached;
    }
    final rgba = await File(pathFor(key)).readAsBytes();
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
        rgba, width, height, ui.PixelFormat.rgba8888, completer.complete);
    final img = await completer.future;
    _images[key] = img;
    if (_images.length > imageCacheCap) {
      final eldest = _images.keys.first;
      _images.remove(eldest)?.dispose();
    }
    return img;
  }

  /// Drop every cached image and delete the backing directory.
  Future<void> dispose() async {
    for (final img in _images.values) {
      img.dispose();
    }
    _images.clear();
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }
}
