import 'dart:typed_data';

import 'package:glimpr/gif_editor/encode/gif_writer.dart';

/// Encode an N-frame 2x2 GIF of solid frames for controller/op tests.
///
/// [colors] indexes a small preset palette; equal entries produce
/// byte-identical frames (duplicate-removal tests rely on that).
Uint8List solidFramesGif({
  required List<int> colors,
  required List<int> delays,
  int loopCount = 0,
}) {
  assert(colors.length == delays.length);
  const presets = [
    [255, 0, 0],
    [0, 255, 0],
    [0, 0, 255],
    [255, 255, 255],
    [255, 255, 0],
    [0, 255, 255],
    [255, 0, 255],
    [0, 0, 0],
  ];
  final frames = <FrameSpec>[];
  for (var i = 0; i < colors.length; i++) {
    final c = presets[colors[i] % presets.length];
    final rgba = Uint8List(2 * 2 * 4);
    for (var p = 0; p < 4; p++) {
      rgba[p * 4] = c[0];
      rgba[p * 4 + 1] = c[1];
      rgba[p * 4 + 2] = c[2];
      rgba[p * 4 + 3] = 255;
    }
    frames.add(FrameSpec(rgba, delays[i]));
  }
  return encodeGifFrames(
      frames: frames, width: 2, height: 2, loopCount: loopCount);
}

/// A hand-assembled, byte-exact 2-frame 2x2 GIF89a used by the import and
/// writer round-trip tests.
///
/// Frame 1 (delay 20cs = 200ms): pixels [red, green, blue, white]
/// Frame 2 (delay 40cs = 400ms): pixels [blue, blue, blue, blue]
/// NETSCAPE loop count 0 (= forever).
///
/// Block map (offsets in comment order):
/// - "GIF89a" header
/// - Logical Screen Descriptor: 2x2, GCT present, 4 colors (packed 0xF1)
/// - Global Color Table: #FF0000 #00FF00 #0000FF #FFFFFF
/// - NETSCAPE2.0 application extension, loop 0
/// - Frame 1: Graphic Control Extension (delay 0x0014), Image Descriptor
///   (0,0 2x2, no LCT), LZW min code size 2, data 0x44 0x34 0x05
///   (codes CLEAR 0 1 2 3 EOI; widths 3,3,3,3,4,4 — the width bump lands one
///   code AFTER the table entry that fills 2^w, the classic-compress rule)
/// - Frame 2: GCE (delay 0x0028), Image Descriptor, LZW data
///   0x94 0x55 (codes CLEAR 2 [2,2] 2 EOI; widths 3,3,3,3,4)
/// - Trailer 0x3B
Uint8List twoFrameGifFixture() => Uint8List.fromList([
      // Header
      0x47, 0x49, 0x46, 0x38, 0x39, 0x61,
      // Logical Screen Descriptor
      0x02, 0x00, 0x02, 0x00, 0xF1, 0x00, 0x00,
      // Global Color Table (red, green, blue, white)
      0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF,
      // NETSCAPE2.0 loop extension (loop forever)
      0x21, 0xFF, 0x0B,
      0x4E, 0x45, 0x54, 0x53, 0x43, 0x41, 0x50, 0x45, 0x32, 0x2E, 0x30,
      0x03, 0x01, 0x00, 0x00, 0x00,
      // Frame 1 GCE: delay 20cs
      0x21, 0xF9, 0x04, 0x00, 0x14, 0x00, 0x00, 0x00,
      // Frame 1 Image Descriptor: 0,0 2x2 no LCT
      0x2C, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x02, 0x00, 0x00,
      // Frame 1 LZW: min code size 2, one 3-byte sub-block
      0x02, 0x03, 0x44, 0x34, 0x05, 0x00,
      // Frame 2 GCE: delay 40cs
      0x21, 0xF9, 0x04, 0x00, 0x28, 0x00, 0x00, 0x00,
      // Frame 2 Image Descriptor
      0x2C, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x02, 0x00, 0x00,
      // Frame 2 LZW
      0x02, 0x02, 0x94, 0x55, 0x00,
      // Trailer
      0x3B,
    ]);
