import 'dart:ui' as ui;

/// Blur radius in LOGICAL pixels and pixelate block size in NATIVE pixels for
/// the raster region tools (fixed in Phase 3; a strength control is deferred).
const double kBlurSigmaLogical = 12;
const double kPixelCellNative = 12;

/// Blur the WHOLE frozen frame once (sigma in native pixels). The blur tool then
/// just masks this image to the dragged region — so there is no per-frame / per-
/// region recompute (which lagged the drag). Runs at app runtime (toImage).
Future<ui.Image> blurWhole(ui.Image frozen, double sigma) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawImage(
    frozen,
    ui.Offset.zero,
    ui.Paint()
      ..imageFilter = ui.ImageFilter.blur(
        sigmaX: sigma,
        sigmaY: sigma,
        tileMode: ui.TileMode.clamp,
      )
      ..filterQuality = ui.FilterQuality.medium,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(frozen.width, frozen.height);
  picture.dispose();
  return image;
}

/// Downsample the WHOLE frozen frame by [cell] native px into a small image. The
/// pixelate tool masks this (upscaled blocky with FilterQuality.none) to the
/// dragged region — computed once when the tool is selected.
Future<ui.Image> pixelateWhole(ui.Image frozen, double cell) async {
  final outW = (frozen.width / cell).clamp(1, 8192).round();
  final outH = (frozen.height / cell).clamp(1, 8192).round();
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawImageRect(
    frozen,
    ui.Rect.fromLTWH(0, 0, frozen.width.toDouble(), frozen.height.toDouble()),
    ui.Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble()),
    ui.Paint()..filterQuality = ui.FilterQuality.medium,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(outW, outH);
  picture.dispose();
  return image;
}
