import 'dart:typed_data';

import 'palette.dart';

/// One frame handed to the writer: full-size RGBA pixels + its delay.
class FrameSpec {
  const FrameSpec(this.rgba, this.delayMs);

  final Uint8List rgba;
  final int delayMs;
}

/// Encode full-size RGBA frames into a GIF89a byte stream.
///
/// Every frame is a complete image (the import path stores composited
/// frames), so each one is written as a full-canvas image with disposal
/// "restore to background" — transparent holes stay transparent and opaque
/// frames fully replace their predecessor. Delays are centiseconds with the
/// mainstream 2cs floor. [loopCount] uses GIF semantics: 0 = forever.
Uint8List encodeGifFrames({
  required List<FrameSpec> frames,
  required int width,
  required int height,
  required int loopCount,
  Palette? palette,
}) {
  assert(frames.isNotEmpty, 'cannot encode an empty GIF');
  final pal = palette ?? Palette.fixed216();
  final out = BytesBuilder(copy: false);

  // Header + Logical Screen Descriptor (256-color global table).
  out.add(const [0x47, 0x49, 0x46, 0x38, 0x39, 0x61]); // "GIF89a"
  out.add(_u16(width));
  out.add(_u16(height));
  out.addByte(0xF7); // GCT present, color res 8, GCT size 256
  out.addByte(0x00); // background color index
  out.addByte(0x00); // pixel aspect ratio
  out.add(pal.rgb);

  // NETSCAPE2.0 loop extension (value 0 = forever, matching the model).
  out.add(const [0x21, 0xFF, 0x0B]);
  out.add('NETSCAPE2.0'.codeUnits);
  out.add([0x03, 0x01, loopCount & 0xFF, (loopCount >> 8) & 0xFF, 0x00]);

  for (final frame in frames) {
    assert(frame.rgba.length == width * height * 4,
        'frame pixels must be width*height*4');
    final pixels = width * height;
    final indices = Uint8List(pixels);
    var transparent = false;
    for (var i = 0; i < pixels; i++) {
      final a = frame.rgba[i * 4 + 3];
      if (a < 128) {
        indices[i] = Palette.transparentIndex;
        transparent = true;
      } else {
        indices[i] = pal.indexOf(
            frame.rgba[i * 4], frame.rgba[i * 4 + 1], frame.rgba[i * 4 + 2]);
      }
    }

    // Graphic Control Extension: disposal 2 (restore to background) + delay.
    final delayCs = (frame.delayMs / 10).round().clamp(2, 0xFFFF);
    out.add([
      0x21, 0xF9, 0x04,
      0x08 | (transparent ? 0x01 : 0x00), // disposal 2, transparency flag
      delayCs & 0xFF, (delayCs >> 8) & 0xFF,
      Palette.transparentIndex,
      0x00,
    ]);

    // Image Descriptor: full canvas, no local color table.
    out.addByte(0x2C);
    out.add(_u16(0));
    out.add(_u16(0));
    out.add(_u16(width));
    out.add(_u16(height));
    out.addByte(0x00);

    // LZW-compressed indices in <=255-byte sub-blocks.
    out.addByte(8); // min code size (256-color table)
    final compressed = _lzwCompress(indices, 8);
    for (var off = 0; off < compressed.length; off += 255) {
      final n = (compressed.length - off).clamp(0, 255);
      out.addByte(n);
      out.add(Uint8List.sublistView(compressed, off, off + n));
    }
    out.addByte(0x00); // block terminator
  }

  out.addByte(0x3B); // trailer
  return out.takeBytes();
}

List<int> _u16(int v) => [v & 0xFF, (v >> 8) & 0xFF];

/// GIF-variant LZW.
///
/// Width handling follows the classic compress lineage every GIF decoder
/// mirrors: a code is emitted at the CURRENT width, THEN the width bumps if
/// the table has already outgrown it — so the first wider code appears one
/// emission after the table entry that filled 2^width (validated against the
/// real decoder by the fixture round-trip tests).
Uint8List _lzwCompress(Uint8List indices, int minCodeSize) {
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
