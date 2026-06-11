import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:path/path.dart' as p;

/// Persisted downscaled-thumbnail cache for the landing gallery (perf-tune
/// F1-3). Decoding 30 recent 5K PNGs eagerly at launch measured a ~578MB RSS
/// transient — cacheHeight bounds the CACHED size, not the decode, and PNG
/// has no reduced-size decode path. Tiles now read ~[height]px sidecar PNGs;
/// missing sidecars are generated with at most [maxConcurrent] decodes in
/// flight, so even a cold cache never piles full-resolution decodes.
///
/// Entries are keyed by (source path, mtime, size): a changed source gets a
/// new key and its stale generations are pruned via the shared path-hash
/// prefix. Lives under ~/Library/Caches — safe to delete at any time.
class ThumbCache {
  ThumbCache({Directory? dir, this.height = 256, this.maxConcurrent = 2})
      : dir = dir ?? _defaultDir();

  final Directory dir;
  final int height;
  final int maxConcurrent;

  int _running = 0;
  final List<Completer<void>> _waiters = [];
  final Map<String, Future<File?>> _inflight = {};

  static Directory _defaultDir() {
    final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
    return Directory(
        p.join(home, 'Library', 'Caches', 'com.howar31.glimpr', 'thumbs'));
  }

  /// The cached thumbnail file for [path], generated when missing. Null when
  /// the source is unreadable/undecodable or the cache dir cannot be written
  /// — callers fall back to decoding the source directly.
  Future<File?> obtain(String path) {
    return _inflight[path] ??= _obtain(path).whenComplete(() {
      _inflight.remove(path);
    });
  }

  Future<File?> _obtain(String path) async {
    final FileStat st;
    try {
      st = await File(path).stat();
    } catch (_) {
      return null;
    }
    if (st.type != FileSystemEntityType.file) return null;
    final key = thumbKey(path, st.modified.millisecondsSinceEpoch, st.size);
    final cached = File(p.join(dir.path, key));
    if (await cached.exists()) return cached;
    await _acquire();
    try {
      return await _generate(path, key);
    } finally {
      _release();
    }
  }

  Future<File?> _generate(String path, String key) async {
    try {
      final bytes = await File(path).readAsBytes();
      // targetHeight bounds the DECODE for formats that support it and the
      // decoded bitmap for the rest; the throttle above bounds the pile-up.
      final codec = await ui.instantiateImageCodec(bytes, targetHeight: height);
      final frame = await codec.getNextFrame();
      codec.dispose();
      final img = frame.image;
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      img.dispose();
      if (data == null) return null;
      await dir.create(recursive: true);
      // Prune stale generations of the same source (shared path-hash prefix).
      final prefix = key.substring(0, key.indexOf('-') + 1);
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final name = p.basename(e.path);
        if (name != key && name.startsWith(prefix)) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
      // Atomic publish: write a temp sibling, then rename over the key.
      final tmp = File(p.join(dir.path, '$key.tmp'));
      await tmp.writeAsBytes(data.buffer.asUint8List(), flush: true);
      return await tmp.rename(p.join(dir.path, key));
    } catch (_) {
      return null;
    }
  }

  Future<void> _acquire() {
    if (_running < maxConcurrent) {
      _running++;
      return Future.value();
    }
    final c = Completer<void>();
    _waiters.add(c);
    return c.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(); // hand the slot over; _running holds
    } else {
      _running--;
    }
  }
}

/// Stable cache filename for (source path, mtime ms, byte size). The path
/// hash leads so every generation of one source shares a prunable prefix.
String thumbKey(String path, int mtimeMs, int size) =>
    '${fnv1a32(path).toRadixString(16)}-$mtimeMs-$size.png';

/// FNV-1a 32-bit over the string's code units — Dart's String.hashCode is
/// not guaranteed stable across runs/versions, a cache filename must be.
int fnv1a32(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}
