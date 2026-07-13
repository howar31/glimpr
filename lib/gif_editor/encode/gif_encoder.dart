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
    final prevPending = _pendingRgba;
    if (prevPending != null) {
      _flushPending();
    }
    _pendingRgba = rgba;
    _pendingDelayMs = delayMs;
    _pendingPalette = palette;
  }

  /// Write the buffered last frame and the trailer.
  void finish() {
    assert(!_finished, 'finish called twice');
    _finished = true;
    if (_pendingRgba != null) _flushPending();
    if (_headerWritten) _emit(const [0x3B]); // trailer
  }

  void _flushPending() {
    final rgba = _pendingRgba!;
    final palette = _pendingPalette!;
    _writeFrame(rgba, _pendingDelayMs, palette);
    _pendingRgba = null;
    _pendingPalette = null;
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

  /// Full-canvas frame with disposal "restore to background" (S1 semantics;
  /// the frame-diff task adds the sub-rectangle path).
  void _writeFrame(Uint8List rgba, int delayMs, Palette palette) {
    final indices = mapFrameToIndices(rgba, width, height, palette,
        dither: options.dither);
    var transparent = false;
    for (final i in indices) {
      if (i == Palette.transparentIndex) {
        transparent = true;
        break;
      }
    }
    final out = BytesBuilder(copy: false);

    // Graphic Control Extension: disposal 2 (restore to background) + delay
    // in centiseconds with the mainstream 2cs floor.
    final delayCs = (delayMs / 10).round().clamp(2, 0xFFFF);
    out.add([
      0x21, 0xF9, 0x04,
      0x08 | (transparent ? 0x01 : 0x00),
      delayCs & 0xFF, (delayCs >> 8) & 0xFF,
      Palette.transparentIndex,
      0x00,
    ]);

    // Image Descriptor: full canvas; a local color table when per-frame.
    final localTable = options.strategy == PaletteStrategy.perFrame;
    out.addByte(0x2C);
    out.add(_u16(0));
    out.add(_u16(0));
    out.add(_u16(width));
    out.add(_u16(height));
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
