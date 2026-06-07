import 'dart:math' as math;
import 'dart:ui' as ui;

/// Region-local raster effects for the Blur / Pixelate tools. Each region is
/// blurred / pixelated over ITS OWN pixels only (not the whole frame), computed
/// once when the region settles (drag-release / move / resize / strength change)
/// — mirroring ShareX's BaseEffectShape. The cache image covers the region rect
/// 1:1 (at reduced resolution); the painter stretches it back over the rect
/// (nearest-neighbour for pixelate -> crisp blocks).
///
/// Strength (DrawStyle.strength, default 12) is authored per tool to reproduce the
/// pre-strength whole-frame look exactly: BLUR reads it as LOGICAL px (native
/// sigma = strength * pixelScale); PIXELATE reads it as NATIVE block px.

/// Native gaussian sigma for a blur of [strengthLogical] logical px at [scale].
double blurSigmaNative(double strengthLogical, double scale) =>
    (strengthLogical * scale).clamp(0.1, 4096);

/// Pixelate block size in NATIVE px for [strengthNative] (>= 1).
double pixelateCellNative(double strengthNative) =>
    strengthNative < 1 ? 1 : strengthNative;

/// Reduced cache dimensions for a blurred region: a gaussian removes detail finer
/// than ~sigma, so storing at ~region/(sigma/2) px is visually identical and far
/// smaller. Always >= 1; capped at 8192.
({int w, int h}) reducedBlurDims(
  double regionW,
  double regionH,
  double sigmaNative,
) {
  final f = math.max(1, (sigmaNative / 2).floor());
  return (
    w: (regionW / f).ceil().clamp(1, 8192),
    h: (regionH / f).ceil().clamp(1, 8192),
  );
}

/// Downsampled-grid dimensions for a pixelated region (one output px per block).
({int w, int h}) pixelateGridDims(
  double regionW,
  double regionH,
  double cellNative,
) {
  final cell = cellNative < 1 ? 1.0 : cellNative;
  return (
    w: (regionW / cell).ceil().clamp(1, 8192),
    h: (regionH / cell).ceil().clamp(1, 8192),
  );
}

/// Blur the [regionNative] rect of [frozen] (native px) at [sigmaNative]. The
/// source is inflated by ~3 sigma (correct edge bleed), blurred, then cropped to
/// the region and downsampled. The returned image covers the region rect 1:1 at
/// reduced resolution. Runs at app runtime (toImage); call off the paint path.
Future<ui.Image> blurRegion(
  ui.Image frozen,
  ui.Rect regionNative,
  double sigmaNative,
) async {
  final frame = ui.Rect.fromLTWH(
    0,
    0,
    frozen.width.toDouble(),
    frozen.height.toDouble(),
  );
  final margin = (sigmaNative * 3).ceil().toDouble();
  final src = regionNative.inflate(margin).intersect(frame);
  // 1) Blur the inflated source at native sigma (full res).
  final r1 = ui.PictureRecorder();
  ui.Canvas(r1).drawImageRect(
    frozen,
    src,
    ui.Rect.fromLTWH(0, 0, src.width, src.height),
    ui.Paint()
      ..imageFilter = ui.ImageFilter.blur(
        sigmaX: sigmaNative,
        sigmaY: sigmaNative,
        tileMode: ui.TileMode.clamp,
      )
      ..filterQuality = ui.FilterQuality.medium,
  );
  final blurred = await r1.endRecording().toImage(
    src.width.ceil(),
    src.height.ceil(),
  );
  // 2) Crop to the region and downsample.
  final dims = reducedBlurDims(
    regionNative.width,
    regionNative.height,
    sigmaNative,
  );
  final r2 = ui.PictureRecorder();
  ui.Canvas(r2).drawImageRect(
    blurred,
    ui.Rect.fromLTWH(
      regionNative.left - src.left,
      regionNative.top - src.top,
      regionNative.width,
      regionNative.height,
    ),
    ui.Rect.fromLTWH(0, 0, dims.w.toDouble(), dims.h.toDouble()),
    ui.Paint()..filterQuality = ui.FilterQuality.medium,
  );
  final out = await r2.endRecording().toImage(dims.w, dims.h);
  blurred.dispose();
  return out;
}

/// Pixelate the [regionNative] rect of [frozen] (native px): a downsample to one
/// px per [cellNative] block. The painter upscales it nearest-neighbour over the
/// region -> blocky mosaic. The grid origin is the region's top-left (matches
/// ShareX; blocks re-align if the region is moved). Runs at app runtime (toImage).
Future<ui.Image> pixelateRegion(
  ui.Image frozen,
  ui.Rect regionNative,
  double cellNative,
) async {
  final dims = pixelateGridDims(
    regionNative.width,
    regionNative.height,
    cellNative,
  );
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawImageRect(
    frozen,
    regionNative,
    ui.Rect.fromLTWH(0, 0, dims.w.toDouble(), dims.h.toDouble()),
    ui.Paint()..filterQuality = ui.FilterQuality.medium,
  );
  return rec.endRecording().toImage(dims.w, dims.h);
}
