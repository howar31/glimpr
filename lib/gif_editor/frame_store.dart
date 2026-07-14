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
  final Map<FrameKey, int> _hashes = {};

  /// Persist one frame of raw RGBA pixels; returns its key.
  Future<FrameKey> put(Uint8List rgba, int width, int height) async {
    assert(rgba.length == width * height * 4,
        'rgba length must be width*height*4');
    final key = FrameKey(_nextKey++);
    _hashes[key] = contentHash(rgba);
    await File(pathFor(key)).writeAsBytes(rgba, flush: false);
    return key;
  }

  /// Content hash of the stored pixels (FNV-1a 64-bit, computed at [put]).
  ///
  /// Duplicate detection compares HASHES ONLY: reading frames back for a
  /// byte confirm would pull the whole document through the UI isolate
  /// (hundreds of MB), and an accidental 64-bit collision between two
  /// different frames of one recording is not a realistic event.
  int hashFor(FrameKey key) => _hashes[key]!;

  /// Allocate a key WITHOUT writing pixels: a worker isolate writes
  /// [pathFor] itself (the store object cannot cross isolates) and the
  /// caller hands the worker-computed content hash back via [registerHash].
  FrameKey reserve() => FrameKey(_nextKey++);

  /// Register the content hash for a [reserve]d key once its file exists.
  void registerHash(FrameKey key, int hash) => _hashes[key] = hash;

  /// The store's content-hash function, public so worker isolates hash the
  /// frames they write with the same algorithm [put] uses.
  static int contentHash(Uint8List bytes) {
    var h = 0xcbf29ce484222325;
    for (final b in bytes) {
      h ^= b;
      h *= 0x100000001b3;
    }
    return h;
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
      // Evict WITHOUT disposing: a RawImage in the filmstrip may still be
      // painting the evicted frame (explicit dispose would crash its next
      // repaint); the ui.Image finalizer reclaims it once unreferenced.
      _images.remove(_images.keys.first);
    }
    return img;
  }

  /// Drop every cached image and delete the backing directory. Best-effort:
  /// on Windows the recursive delete fails with a sharing violation while an
  /// async frame read is still in flight (document swap / teardown race) —
  /// swallow it and leave the session dir to the OS's temp cleanup rather
  /// than let the error escape an unawaited dispose.
  Future<void> dispose() async {
    for (final img in _images.values) {
      img.dispose();
    }
    _images.clear();
    try {
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
      }
    } on FileSystemException {
      // Locked file on Windows; the dir is under the system temp location.
    }
  }
}
