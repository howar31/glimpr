import 'dart:typed_data';

/// Pure RGBA-buffer pixel transforms for the GIF editor's canvas operations
/// (crop / flip / rotate / resize). All functions return a NEW buffer and
/// never mutate their input; buffers are tightly packed rows of
/// width * height * 4 bytes.

/// Copy the [cw] x [ch] rectangle at ([cx], [cy]) out of a [w] x [h] frame.
Uint8List cropRect(
    Uint8List src, int w, int h, int cx, int cy, int cw, int ch) {
  assert(cx >= 0 && cy >= 0 && cw > 0 && ch > 0);
  assert(cx + cw <= w && cy + ch <= h);
  final out = Uint8List(cw * ch * 4);
  for (var y = 0; y < ch; y++) {
    final srcOff = ((cy + y) * w + cx) * 4;
    out.setRange(y * cw * 4, (y + 1) * cw * 4, src, srcOff);
  }
  return out;
}

/// Mirror columns (left-right).
Uint8List flipH(Uint8List src, int w, int h) {
  final out = Uint8List(w * h * 4);
  final s = Uint32List.view(src.buffer, src.offsetInBytes, w * h);
  final d = Uint32List.view(out.buffer, 0, w * h);
  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      d[row + x] = s[row + (w - 1 - x)];
    }
  }
  return out;
}

/// Mirror rows (top-bottom).
Uint8List flipV(Uint8List src, int w, int h) {
  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    out.setRange(
        y * w * 4, (y + 1) * w * 4, src, (h - 1 - y) * w * 4);
  }
  return out;
}

/// Rotate a quarter turn clockwise: output is h x w; src (x, y) lands at
/// output (h - 1 - y, x).
Uint8List rotate90cw(Uint8List src, int w, int h) {
  final out = Uint8List(w * h * 4);
  final s = Uint32List.view(src.buffer, src.offsetInBytes, w * h);
  final d = Uint32List.view(out.buffer, 0, w * h);
  final ow = h; // output width
  for (var y = 0; y < h; y++) {
    final row = y * w;
    final dx = h - 1 - y;
    for (var x = 0; x < w; x++) {
      d[x * ow + dx] = s[row + x];
    }
  }
  return out;
}

/// Rotate a quarter turn counter-clockwise: output is h x w; src (x, y)
/// lands at output (y, w - 1 - x).
Uint8List rotate90ccw(Uint8List src, int w, int h) {
  final out = Uint8List(w * h * 4);
  final s = Uint32List.view(src.buffer, src.offsetInBytes, w * h);
  final d = Uint32List.view(out.buffer, 0, w * h);
  final ow = h;
  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      d[(w - 1 - x) * ow + y] = s[row + x];
    }
  }
  return out;
}

/// Half turn (same dimensions).
Uint8List rotate180(Uint8List src, int w, int h) {
  final n = w * h;
  final out = Uint8List(n * 4);
  final s = Uint32List.view(src.buffer, src.offsetInBytes, n);
  final d = Uint32List.view(out.buffer, 0, n);
  for (var i = 0; i < n; i++) {
    d[i] = s[n - 1 - i];
  }
  return out;
}

/// Bilinear resample to [ow] x [oh]. Channels interpolate independently
/// (straight alpha); an identity size is a plain copy.
Uint8List resizeBilinear(
    Uint8List src, int w, int h, int ow, int oh) {
  assert(ow > 0 && oh > 0);
  if (ow == w && oh == h) return Uint8List.fromList(src);
  final out = Uint8List(ow * oh * 4);
  // Map output centers back into source space (align centers so edges
  // stay edges and a solid image stays solid at any scale).
  final sx = w / ow;
  final sy = h / oh;
  for (var y = 0; y < oh; y++) {
    var fy = (y + 0.5) * sy - 0.5;
    if (fy < 0) fy = 0;
    var y0 = fy.floor();
    if (y0 > h - 1) y0 = h - 1;
    final y1 = y0 + 1 > h - 1 ? h - 1 : y0 + 1;
    final wy = fy - y0;
    for (var x = 0; x < ow; x++) {
      var fx = (x + 0.5) * sx - 0.5;
      if (fx < 0) fx = 0;
      var x0 = fx.floor();
      if (x0 > w - 1) x0 = w - 1;
      final x1 = x0 + 1 > w - 1 ? w - 1 : x0 + 1;
      final wx = fx - x0;
      final o = (y * ow + x) * 4;
      final p00 = (y0 * w + x0) * 4;
      final p01 = (y0 * w + x1) * 4;
      final p10 = (y1 * w + x0) * 4;
      final p11 = (y1 * w + x1) * 4;
      for (var c = 0; c < 4; c++) {
        final top = src[p00 + c] + (src[p01 + c] - src[p00 + c]) * wx;
        final bot = src[p10 + c] + (src[p11 + c] - src[p10 + c]) * wx;
        out[o + c] = (top + (bot - top) * wy).round().clamp(0, 255);
      }
    }
  }
  return out;
}
