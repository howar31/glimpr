import 'dart:typed_data';

/// A 256-entry GIF palette plus RGB→index mapping.
///
/// Two constructions: [Palette.fixed216] (the S1 uniform cube, kept as the
/// degenerate-input fallback and for tests) and [Palette.medianCut] (the real
/// per-document quantizer). The writer contract is shared: index
/// [transparentIndex] is reserved for transparency and [indexOf] never
/// returns it.
class Palette {
  Palette._(this.rgb, [this._entryCount = transparentIndex]);

  /// Index reserved for the transparent pixel (GCE transparent color index).
  static const int transparentIndex = 255;

  /// 256 * 3 bytes, RGB per entry. Entry [transparentIndex] is a slot the
  /// mapper never returns for opaque pixels.
  final Uint8List rgb;

  /// How many leading entries are real colors (fixed216 uses the arithmetic
  /// cube mapping and ignores this; median-cut palettes scan only this many).
  final int _entryCount;

  /// Memoized nearest-entry lookups (median-cut palettes only). Bounded by
  /// the number of distinct colors ever queried for one palette instance.
  final Map<int, int> _nearest = {};

  /// Uses the arithmetic cube fast path in [indexOf] instead of a scan.
  bool _isFixedCube = false;

  /// The uniform web-style cube: levels 0/51/102/153/204/255 per channel at
  /// indices 0..215, a gray ramp at 216..254, and the transparent slot at 255.
  factory Palette.fixed216() {
    final rgb = Uint8List(256 * 3);
    const levels = [0, 51, 102, 153, 204, 255];
    var i = 0;
    for (final r in levels) {
      for (final g in levels) {
        for (final b in levels) {
          rgb[i * 3] = r;
          rgb[i * 3 + 1] = g;
          rgb[i * 3 + 2] = b;
          i++;
        }
      }
    }
    // 39 grays between the cube's 51-steps (216..254).
    for (var g = 0; g < 39; g++) {
      final v = ((g + 1) * 255 / 40).round();
      rgb[(216 + g) * 3] = v;
      rgb[(216 + g) * 3 + 1] = v;
      rgb[(216 + g) * 3 + 2] = v;
    }
    return Palette._(rgb).._isFixedCube = true;
  }

  /// Median-cut quantizer over the opaque pixels of [rgbaBuffers].
  ///
  /// Builds a color histogram (every [sampleStride]-th pixel; alpha < 128 is
  /// skipped — a transparent pixel has no color), then classic median cut:
  /// while under 255 entries, split the box with the widest channel range at
  /// its weighted median. Documents with <= 255 distinct opaque colors get
  /// every color EXACTLY (each box degenerates to one color), which the
  /// round-trip tests rely on. Deterministic: maps iterate in insertion
  /// order and every sort carries a full-key tiebreaker. An empty sample set
  /// (all-transparent input) falls back to [Palette.fixed216].
  factory Palette.medianCut(Iterable<Uint8List> rgbaBuffers,
      {int sampleStride = 1}) {
    assert(sampleStride >= 1);
    final counts = <int, int>{};
    for (final buf in rgbaBuffers) {
      final pixels = buf.length ~/ 4;
      for (var i = 0; i < pixels; i += sampleStride) {
        final o = i * 4;
        if (buf[o + 3] < 128) continue;
        final key = (buf[o] << 16) | (buf[o + 1] << 8) | buf[o + 2];
        counts[key] = (counts[key] ?? 0) + 1;
      }
    }
    if (counts.isEmpty) return Palette.fixed216();

    const maxEntries = transparentIndex; // 255 opaque slots
    final rgb = Uint8List(256 * 3);
    var n = 0;
    if (counts.length <= maxEntries) {
      for (final key in counts.keys) {
        rgb[n * 3] = (key >> 16) & 0xFF;
        rgb[n * 3 + 1] = (key >> 8) & 0xFF;
        rgb[n * 3 + 2] = key & 0xFF;
        n++;
      }
    } else {
      final boxes = <_Box>[_Box(counts.keys.toList(), counts)];
      while (boxes.length < maxEntries) {
        // Widest box first; index breaks ties so the pick is deterministic.
        _Box? widest;
        var widestRange = 0;
        for (final box in boxes) {
          if (box.colors.length < 2) continue;
          if (box.range > widestRange) {
            widestRange = box.range;
            widest = box;
          }
        }
        if (widest == null) break; // nothing left to split
        boxes.remove(widest);
        boxes.addAll(widest.split());
      }
      for (final box in boxes) {
        final mean = box.weightedMean();
        rgb[n * 3] = mean[0];
        rgb[n * 3 + 1] = mean[1];
        rgb[n * 3 + 2] = mean[2];
        n++;
      }
    }
    return Palette._(rgb, n);
  }

  /// Nearest palette index for an opaque RGB pixel (never the transparent
  /// slot). The fixed cube quantizes arithmetically; median-cut palettes do
  /// a memoized nearest scan over their entries.
  int indexOf(int r, int g, int b) {
    if (_isFixedCube) {
      final qr = ((r * 5) + 127) ~/ 255;
      final qg = ((g * 5) + 127) ~/ 255;
      final qb = ((b * 5) + 127) ~/ 255;
      return qr * 36 + qg * 6 + qb;
    }
    final key = (r << 16) | (g << 8) | b;
    final hit = _nearest[key];
    if (hit != null) return hit;
    var best = 0;
    var bestD = 1 << 30;
    for (var i = 0; i < _entryCount; i++) {
      final dr = rgb[i * 3] - r;
      final dg = rgb[i * 3 + 1] - g;
      final db = rgb[i * 3 + 2] - b;
      final d = dr * dr + dg * dg + db * db;
      if (d < bestD) {
        bestD = d;
        best = i;
        if (d == 0) break;
      }
    }
    _nearest[key] = best;
    return best;
  }
}

/// One median-cut box: a set of distinct colors plus the shared histogram.
class _Box {
  _Box(this.colors, this.counts) {
    _computeRange();
  }

  final List<int> colors; // packed 0xRRGGBB keys
  final Map<int, int> counts;

  late int range; // widest channel spread
  late int _channel; // 0 = r, 1 = g, 2 = b (the widest one)

  static int _chan(int key, int c) => (key >> (16 - c * 8)) & 0xFF;

  void _computeRange() {
    var minR = 255, maxR = 0, minG = 255, maxG = 0, minB = 255, maxB = 0;
    for (final key in colors) {
      final r = (key >> 16) & 0xFF, g = (key >> 8) & 0xFF, b = key & 0xFF;
      if (r < minR) minR = r;
      if (r > maxR) maxR = r;
      if (g < minG) minG = g;
      if (g > maxG) maxG = g;
      if (b < minB) minB = b;
      if (b > maxB) maxB = b;
    }
    final spreads = [maxR - minR, maxG - minG, maxB - minB];
    _channel = 0;
    range = spreads[0];
    for (var c = 1; c < 3; c++) {
      if (spreads[c] > range) {
        range = spreads[c];
        _channel = c;
      }
    }
  }

  /// Split at the weighted median of the widest channel; both halves stay
  /// non-empty. Sort key includes the full packed color so equal channel
  /// values order deterministically (List.sort is not stable).
  List<_Box> split() {
    final c = _channel;
    colors.sort((a, b) {
      final d = _chan(a, c) - _chan(b, c);
      return d != 0 ? d : a - b;
    });
    var total = 0;
    for (final key in colors) {
      total += counts[key]!;
    }
    var acc = 0;
    var cut = 0;
    for (var i = 0; i < colors.length; i++) {
      acc += counts[colors[i]]!;
      if (acc * 2 >= total) {
        cut = i + 1;
        break;
      }
    }
    if (cut >= colors.length) cut = colors.length - 1;
    if (cut < 1) cut = 1;
    return [
      _Box(colors.sublist(0, cut), counts),
      _Box(colors.sublist(cut), counts),
    ];
  }

  /// Count-weighted mean color of the box.
  List<int> weightedMean() {
    var sr = 0, sg = 0, sb = 0, w = 0;
    for (final key in colors) {
      final count = counts[key]!;
      sr += ((key >> 16) & 0xFF) * count;
      sg += ((key >> 8) & 0xFF) * count;
      sb += (key & 0xFF) * count;
      w += count;
    }
    return [(sr / w).round(), (sg / w).round(), (sb / w).round()];
  }
}
