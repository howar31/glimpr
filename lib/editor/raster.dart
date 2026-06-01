import 'dart:ui' as ui;

/// Builds the downsampled "mosaic" for a pixelate region: the frozen image's
/// native pixels under [rectLogical], averaged down by [cell] (native px per
/// block). The painter then upscales this small image blocky
/// (`FilterQuality.none`). Returns a tiny `ui.Image`.
///
/// Runs at app runtime (uses `picture.toImage`, which works on-device but hangs
/// in headless `flutter_test` — so this is exercised only on-device).
Future<ui.Image> pixelateRegion(
  ui.Image frozen,
  ui.Rect rectLogical,
  double scaleFactor,
  double cell,
) async {
  final srcW = rectLogical.width * scaleFactor;
  final srcH = rectLogical.height * scaleFactor;
  final src = ui.Rect.fromLTWH(
      rectLogical.left * scaleFactor, rectLogical.top * scaleFactor, srcW, srcH);
  final outW = (srcW / cell).clamp(1, 4096).round();
  final outH = (srcH / cell).clamp(1, 4096).round();
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  // Average the region down (medium quality) into a tiny image.
  canvas.drawImageRect(
    frozen,
    src,
    ui.Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble()),
    ui.Paint()..filterQuality = ui.FilterQuality.medium,
  );
  final picture = recorder.endRecording();
  return picture.toImage(outW, outH);
}
