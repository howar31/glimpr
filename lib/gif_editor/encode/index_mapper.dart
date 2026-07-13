import 'dart:typed_data';

import 'palette.dart';

/// Map one full-size RGBA frame to palette indices.
///
/// Plain mode is a straight per-pixel [Palette.indexOf]. Dither mode adds
/// Floyd-Steinberg error diffusion (weights 7/16 right, 3/16 down-left,
/// 5/16 down, 1/16 down-right). Transparent pixels (alpha < 128) always map
/// to [Palette.transparentIndex]; they neither receive nor propagate error,
/// so quantization noise never leaks across holes. On an image whose colors
/// are all exactly in the palette the two modes are identical (zero error).
Uint8List mapFrameToIndices(
  Uint8List rgba,
  int width,
  int height,
  Palette palette, {
  required bool dither,
}) {
  assert(rgba.length == width * height * 4);
  final out = Uint8List(width * height);
  if (!dither) {
    for (var i = 0; i < width * height; i++) {
      final o = i * 4;
      out[i] = rgba[o + 3] < 128
          ? Palette.transparentIndex
          : palette.indexOf(rgba[o], rgba[o + 1], rgba[o + 2]);
    }
    return out;
  }

  // Error rows, one slot of padding on each side so the x-1/x+1 diffusion
  // never needs boundary checks. Swapped per row.
  var curR = Float32List(width + 2), curG = Float32List(width + 2),
      curB = Float32List(width + 2);
  var nextR = Float32List(width + 2), nextG = Float32List(width + 2),
      nextB = Float32List(width + 2);

  int clamp255(double v) => v < 0 ? 0 : (v > 255 ? 255 : v.round());

  for (var y = 0; y < height; y++) {
    final rowBase = y * width;
    for (var x = 0; x < width; x++) {
      final o = (rowBase + x) * 4;
      if (rgba[o + 3] < 128) {
        out[rowBase + x] = Palette.transparentIndex;
        continue; // incoming error at a hole is dropped, nothing propagates
      }
      final r = clamp255(rgba[o] + curR[x + 1]);
      final g = clamp255(rgba[o + 1] + curG[x + 1]);
      final b = clamp255(rgba[o + 2] + curB[x + 1]);
      final idx = palette.indexOf(r, g, b);
      out[rowBase + x] = idx;
      final er = (r - palette.rgb[idx * 3]).toDouble();
      final eg = (g - palette.rgb[idx * 3 + 1]).toDouble();
      final eb = (b - palette.rgb[idx * 3 + 2]).toDouble();
      curR[x + 2] += er * (7 / 16);
      curG[x + 2] += eg * (7 / 16);
      curB[x + 2] += eb * (7 / 16);
      nextR[x] += er * (3 / 16);
      nextG[x] += eg * (3 / 16);
      nextB[x] += eb * (3 / 16);
      nextR[x + 1] += er * (5 / 16);
      nextG[x + 1] += eg * (5 / 16);
      nextB[x + 1] += eb * (5 / 16);
      nextR[x + 2] += er * (1 / 16);
      nextG[x + 2] += eg * (1 / 16);
      nextB[x + 2] += eb * (1 / 16);
    }
    // Advance: next becomes current, the emptied row is reused as next.
    final tr = curR, tg = curG, tb = curB;
    curR = nextR;
    curG = nextG;
    curB = nextB;
    nextR = tr..fillRange(0, width + 2, 0);
    nextG = tg..fillRange(0, width + 2, 0);
    nextB = tb..fillRange(0, width + 2, 0);
  }
  return out;
}
