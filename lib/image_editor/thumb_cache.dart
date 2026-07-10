import 'dart:async';
import 'dart:math' as math;
import '../platform_gate.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:path/path.dart' as p;

/// Persisted thumbnail cache for the landing gallery (perf-tune F1-3).
/// Decoding 30 recent 5K PNGs eagerly at launch measured a ~578MB RSS
/// transient, so tiles read small sidecar PNGs instead; missing sidecars are
/// generated with at most [maxConcurrent] decodes in flight, so even a cold
/// cache never piles full-resolution decodes.
///
/// A sidecar is the tile's COVER SLICE, not a whole-image miniature: the tile
/// paints BoxFit.cover / topCenter into a [boxWidth]x[boxHeight] (device px)
/// window, so the source is cropped to that aspect FIRST (top slice for tall
/// sources, horizontally-centered for wide) and downscaled second. Bounding
/// the whole image by height alone starved a tall screenshot's width (a
/// 631x3733 source became 43px wide) and the tile upscaled it into blur.
///
/// Entries are keyed by (source path, mtime, size) + a format version: a
/// changed source gets a new key and its stale generations are pruned via the
/// shared path-hash prefix. Lives under ~/Library/Caches (macOS) /
/// %LOCALAPPDATA% (Windows) — safe to delete at any time.
class ThumbCache {
  ThumbCache(
      {Directory? dir,
      this.boxWidth = 620,
      this.boxHeight = 456,
      this.maxConcurrent = 2})
      : dir = dir ?? _defaultDir();

  final Directory dir;

  /// The canonical tile display window in DEVICE px: 2x the largest gallery
  /// tile's thumbnail area (kGalleryTileMax 310 x ~228 logical), so tiles stay
  /// native-or-down on 2x displays at every grid size.
  final int boxWidth;
  final int boxHeight;
  final int maxConcurrent;

  int _running = 0;
  final List<Completer<void>> _waiters = [];
  final Map<String, Future<File?>> _inflight = {};

  static Directory _defaultDir() {
    if (platformIsWindows) {
      // HOME is normally unset on Windows and ~/Library/Caches is a macOS
      // convention — the old path fell back to the periodically-cleaned %TEMP%,
      // losing the cache's persistence. LOCALAPPDATA is the Windows analogue.
      final base = Platform.environment['LOCALAPPDATA'] ??
          Directory.systemTemp.path;
      return Directory(p.join(base, 'com.howar31.glimpr', 'thumbs'));
    }
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
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? desc;
    try {
      final bytes = await File(path).readAsBytes();
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      desc = await ui.ImageDescriptor.encoded(buffer);
      final srcW = desc.width;
      final srcH = desc.height;
      // Bound the decode on the axis the tile's cover BINDS (tall sources by
      // width, wide by height) — the other axis follows the source aspect and
      // gets cropped below. Never upscales: the bound caps at the native size.
      final tall = srcW * boxHeight < srcH * boxWidth;
      final codec = await desc.instantiateCodec(
        targetWidth: tall ? math.min(boxWidth, srcW) : null,
        targetHeight: tall ? null : math.min(boxHeight, srcH),
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      var img = frame.image;
      // Crop to the box aspect the way the tile displays it: top slice,
      // horizontally centered (BoxFit.cover + Alignment.topCenter).
      final cropW =
          math.min(img.width, (img.height * boxWidth / boxHeight).round());
      final cropH =
          math.min(img.height, (img.width * boxHeight / boxWidth).round());
      if (cropW != img.width || cropH != img.height) {
        final left = ((img.width - cropW) / 2).floorToDouble();
        final rec = ui.PictureRecorder();
        ui.Canvas(rec).drawImageRect(
          img,
          ui.Rect.fromLTWH(left, 0, cropW.toDouble(), cropH.toDouble()),
          ui.Rect.fromLTWH(0, 0, cropW.toDouble(), cropH.toDouble()),
          ui.Paint(),
        );
        final pic = rec.endRecording();
        final cropped = await pic.toImage(cropW, cropH);
        pic.dispose();
        img.dispose();
        img = cropped;
      }
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
    } finally {
      desc?.dispose();
      buffer?.dispose();
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
/// hash leads so every generation of one source shares a prunable prefix; the
/// format version invalidates sidecars from older pipelines (v2 = cover-crop).
String thumbKey(String path, int mtimeMs, int size) =>
    '${fnv1a32(path).toRadixString(16)}-v2-$mtimeMs-$size.png';

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
