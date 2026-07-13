import 'dart:typed_data';

import 'index_mapper.dart';
import 'palette.dart';

/// Which color table the encoder writes.
///
/// [global]: one table for the whole file (best size; frame-diff frames can
/// reference each other's colors). [perFrame]: a local color table per image
/// (best fidelity when the colors drift across frames; costs 768 bytes each).
enum PaletteStrategy { global, perFrame }

/// Export-time encoder knobs (the S2 options surface).
class GifEncodeOptions {
  const GifEncodeOptions({
    this.strategy = PaletteStrategy.global,
    this.dither = false,
    this.optimizeFrameDiff = false,
    this.loopCount = 0,
  });

  final PaletteStrategy strategy;
  final bool dither;

  /// Emit only the changed sub-rectangle per frame, painting unchanged
  /// pixels inside it transparent (arrives with the frame-diff task; the
  /// false path is the S1 full-frame behavior).
  final bool optimizeFrameDiff;

  /// GIF semantics: 0 = loop forever.
  final int loopCount;
}

/// Streaming GIF89a encoder: frames are added one at a time and encoded
/// bytes leave through the [emit] callback, so the caller never holds more
/// than a couple of frames in memory. One frame is buffered internally
/// (frame-diff disposal decisions need one frame of lookahead).
class GifEncoder {
  GifEncoder(
    this._emit, {
    required this.width,
    required this.height,
    required this.options,
    this.globalPalette,
  }) {
    assert(
        options.strategy == PaletteStrategy.perFrame ||
            globalPalette != null,
        'the global strategy needs a pre-built palette (sampling pass)');
  }

  final void Function(List<int> bytes) _emit;
  final int width;
  final int height;
  final GifEncodeOptions options;
  final Palette? globalPalette;

  bool _headerWritten = false;
  bool _finished = false;

  // One-frame lookahead buffer (see class doc).
  Uint8List? _pendingRgba;
  int _pendingDelayMs = 0;
  Palette? _pendingPalette;

  // Frame-diff state: the raw pixels of the last WRITTEN frame, and whether
  // that frame was written with disposal "restore to background" (the next
  // frame then paints onto a cleared canvas and must be full-rect).
  Uint8List? _prevRgba;
  bool _canvasCleared = false;

  /// Queue one full-size RGBA frame. The PREVIOUS frame is what actually
  /// gets written (its encoding may depend on this one).
  void addFrame(Uint8List rgba, int delayMs) {
    assert(!_finished, 'addFrame after finish');
    assert(rgba.length == width * height * 4,
        'frame pixels must be width*height*4');
    final palette = options.strategy == PaletteStrategy.perFrame
        ? Palette.medianCut([rgba])
        : globalPalette!;
    if (!_headerWritten) {
      _writeHeader(palette);
      _headerWritten = true;
    }
    if (_pendingRgba != null) {
      _flushPending(
          nextRegresses:
              options.optimizeFrameDiff && _regresses(rgba, _pendingRgba!));
    }
    _pendingRgba = rgba;
    _pendingDelayMs = delayMs;
    _pendingPalette = palette;
  }

  /// Write the buffered last frame and the trailer.
  void finish() {
    assert(!_finished, 'finish called twice');
    _finished = true;
    if (_pendingRgba != null) _flushPending(nextRegresses: false);
    if (_headerWritten) _emit(const [0x3B]); // trailer
  }

  /// Does [next] turn any of [prev]'s opaque pixels transparent? Such a
  /// change cannot be painted over (a transparent index KEEPS the old pixel),
  /// so the canvas has to be cleared first.
  static bool _regresses(Uint8List next, Uint8List prev) {
    for (var i = 3; i < next.length; i += 4) {
      if (next[i] < 128 && prev[i] >= 128) return true;
    }
    return false;
  }

  void _flushPending({required bool nextRegresses}) {
    final rgba = _pendingRgba!;
    final palette = _pendingPalette!;
    if (!options.optimizeFrameDiff) {
      // S1 semantics: every frame full-canvas, restore to background.
      _writeImage(
        left: 0,
        top: 0,
        w: width,
        h: height,
        indices: mapFrameToIndices(rgba, width, height, palette,
            dither: options.dither),
        disposal: 2,
        delayMs: _pendingDelayMs,
        palette: palette,
      );
    } else {
      _writeOptimized(rgba, _pendingDelayMs, palette, nextRegresses);
      _prevRgba = rgba;
    }
    _pendingRgba = null;
    _pendingPalette = null;
  }

  /// Frame-diff emission. Invariant that keeps the chain correct: along a
  /// run of disposal-1 frames holes only ever shrink (a growing hole is a
  /// regression and restarts the run), so a canvas pixel is clear exactly
  /// where the current frame is transparent — full-rect emissions may paint
  /// their holes with the transparent index at any point in the run.
  void _writeOptimized(
      Uint8List rgba, int delayMs, Palette palette, bool nextRegresses) {
    final prev = _prevRgba;
    final mustFull = prev == null || _canvasCleared;
    if (mustFull || nextRegresses) {
      _writeImage(
        left: 0,
        top: 0,
        w: width,
        h: height,
        indices: mapFrameToIndices(rgba, width, height, palette,
            dither: options.dither),
        // Restore-to-background only when the NEXT frame needs a cleared
        // canvas; otherwise leave the composite in place and keep diffing.
        disposal: nextRegresses ? 2 : 1,
        delayMs: delayMs,
        palette: palette,
      );
      _canvasCleared = nextRegresses;
      return;
    }

    bool differsAt(int o) {
      final opaqueNew = rgba[o + 3] >= 128;
      final opaqueOld = prev[o + 3] >= 128;
      if (opaqueNew != opaqueOld) return true;
      return opaqueNew &&
          (rgba[o] != prev[o] ||
              rgba[o + 1] != prev[o + 1] ||
              rgba[o + 2] != prev[o + 2]);
    }

    // Bounding box of changed pixels.
    var minX = width, minY = height, maxX = -1, maxY = -1;
    for (var y = 0; y < height; y++) {
      final rowBase = y * width;
      for (var x = 0; x < width; x++) {
        if (!differsAt((rowBase + x) * 4)) continue;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }

    if (maxX < 0) {
      // Identical frames: a 1x1 transparent stub carries just the delay.
      _writeImage(
        left: 0,
        top: 0,
        w: 1,
        h: 1,
        indices: Uint8List.fromList(const [Palette.transparentIndex]),
        disposal: 1,
        delayMs: delayMs,
        palette: palette,
      );
      _canvasCleared = false;
      return;
    }

    // Map the WHOLE frame (dither needs full-frame error context), then lift
    // the changed pixels; unchanged ones paint transparent so the previous
    // composite shows through.
    final full = mapFrameToIndices(rgba, width, height, palette,
        dither: options.dither);
    final rw = maxX - minX + 1;
    final rh = maxY - minY + 1;
    final rect = Uint8List(rw * rh);
    var k = 0;
    for (var y = minY; y <= maxY; y++) {
      final rowBase = y * width;
      for (var x = minX; x <= maxX; x++) {
        final p = rowBase + x;
        rect[k++] = differsAt(p * 4) ? full[p] : Palette.transparentIndex;
      }
    }
    _writeImage(
      left: minX,
      top: minY,
      w: rw,
      h: rh,
      indices: rect,
      disposal: 1,
      delayMs: delayMs,
      palette: palette,
    );
    _canvasCleared = false;
  }

  void _writeHeader(Palette firstPalette) {
    final out = BytesBuilder(copy: false);
    out.add(const [0x47, 0x49, 0x46, 0x38, 0x39, 0x61]); // "GIF89a"
    out.add(_u16(width));
    out.add(_u16(height));
    out.addByte(0xF7); // GCT present, color res 8, GCT size 256
    out.addByte(0x00); // background color index
    out.addByte(0x00); // pixel aspect ratio
    // The GCT: the global palette, or the first frame's palette when every
    // image carries its own local table (the byte must still be a valid
    // 768-byte block either way).
    out.add((globalPalette ?? firstPalette).rgb);
    // NETSCAPE2.0 loop extension (value 0 = forever, matching the model).
    out.add(const [0x21, 0xFF, 0x0B]);
    out.add('NETSCAPE2.0'.codeUnits);
    final loop = options.loopCount;
    out.add([0x03, 0x01, loop & 0xFF, (loop >> 8) & 0xFF, 0x00]);
    _emit(out.takeBytes());
  }

  /// One GCE + image descriptor + pixel data block at ([left], [top]) sized
  /// [w] x [h]. [disposal] uses GIF semantics (1 = leave, 2 = restore to
  /// background); the transparency flag is set whenever [indices] contain
  /// the reserved slot.
  void _writeImage({
    required int left,
    required int top,
    required int w,
    required int h,
    required Uint8List indices,
    required int disposal,
    required int delayMs,
    required Palette palette,
  }) {
    assert(indices.length == w * h);
    // DECODER QUIRK (probed 2026-07-14): Flutter's GIF decoder fails
    // getPixels on any TRANSPARENT frame that follows a restore-to-background
    // frame whose own transparency flag was off, so disposal-2 frames always
    // advertise the flag. Harmless everywhere: the flag only assigns meaning
    // to index 255, and nothing below emits 255 without wanting a hole.
    var transparent = disposal == 2;
    if (!transparent) {
      for (final i in indices) {
        if (i == Palette.transparentIndex) {
          transparent = true;
          break;
        }
      }
    }
    final out = BytesBuilder(copy: false);

    // Graphic Control Extension: disposal + delay in centiseconds with the
    // mainstream 2cs floor.
    final delayCs = (delayMs / 10).round().clamp(2, 0xFFFF);
    out.add([
      0x21, 0xF9, 0x04,
      (disposal << 2) | (transparent ? 0x01 : 0x00),
      delayCs & 0xFF, (delayCs >> 8) & 0xFF,
      Palette.transparentIndex,
      0x00,
    ]);

    // Image Descriptor; a local color table when per-frame.
    final localTable = options.strategy == PaletteStrategy.perFrame;
    out.addByte(0x2C);
    out.add(_u16(left));
    out.add(_u16(top));
    out.add(_u16(w));
    out.add(_u16(h));
    out.addByte(localTable ? 0x87 : 0x00); // LCT present, size 256
    if (localTable) out.add(palette.rgb);

    // LZW-compressed indices in <=255-byte sub-blocks.
    out.addByte(8); // min code size (256-color table)
    final compressed = lzwCompress(indices, 8);
    for (var off = 0; off < compressed.length; off += 255) {
      final n = (compressed.length - off).clamp(0, 255);
      out.addByte(n);
      out.add(Uint8List.sublistView(compressed, off, off + n));
    }
    out.addByte(0x00); // block terminator
    _emit(out.takeBytes());
  }
}

List<int> _u16(int v) => [v & 0xFF, (v >> 8) & 0xFF];

/// GIF-variant LZW.
///
/// Width handling follows the classic compress lineage every GIF decoder
/// mirrors: a code is emitted at the CURRENT width, THEN the width bumps if
/// the table has already outgrown it — so the first wider code appears one
/// emission after the table entry that filled 2^width (validated against the
/// real decoder by the fixture round-trip tests).
Uint8List lzwCompress(Uint8List indices, int minCodeSize) {
  final clearCode = 1 << minCodeSize;
  final eoiCode = clearCode + 1;

  final out = BytesBuilder(copy: false);
  var bitBuffer = 0;
  var bitCount = 0;
  var codeSize = minCodeSize + 1;
  var maxCode = (1 << codeSize) - 1;
  var nextCode = eoiCode + 1;
  // Dictionary keyed by (prefixCode << 8) | nextIndex; roots are implicit.
  var dict = <int, int>{};

  void emit(int code) {
    bitBuffer |= code << bitCount;
    bitCount += codeSize;
    while (bitCount >= 8) {
      out.addByte(bitBuffer & 0xFF);
      bitBuffer >>= 8;
      bitCount -= 8;
    }
    // Classic rule: the bump takes effect AFTER this emission.
    if (nextCode > maxCode && codeSize < 12) {
      codeSize++;
      maxCode = (1 << codeSize) - 1;
    }
  }

  emit(clearCode);
  var current = indices[0];
  for (var i = 1; i < indices.length; i++) {
    final k = indices[i];
    final key = (current << 8) | k;
    final found = dict[key];
    if (found != null) {
      current = found;
      continue;
    }
    emit(current);
    if (nextCode < 4096) {
      dict[key] = nextCode++;
    } else {
      // Table full: reset, matching the decoder's clear handling.
      emit(clearCode);
      dict = <int, int>{};
      codeSize = minCodeSize + 1;
      maxCode = (1 << codeSize) - 1;
      nextCode = eoiCode + 1;
    }
    current = k;
  }
  emit(current);
  emit(eoiCode);
  if (bitCount > 0) {
    out.addByte(bitBuffer & 0xFF);
  }
  return out.takeBytes();
}
