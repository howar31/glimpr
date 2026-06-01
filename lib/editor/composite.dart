import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'drawable.dart';
import 'drawable_painter.dart';
import 'raster.dart';

/// Native-pixel crop rect for [selectionLogical] (logical overlay coords), or
/// the whole display when null. Clamped to the native image bounds.
Rect nativeCropRect({
  required Rect? selectionLogical,
  required Size logicalSize,
  required double scaleFactor,
}) {
  final full = Rect.fromLTWH(
    0,
    0,
    logicalSize.width * scaleFactor,
    logicalSize.height * scaleFactor,
  );
  if (selectionLogical == null) return full;
  final scaled = Rect.fromLTRB(
    selectionLogical.left * scaleFactor,
    selectionLogical.top * scaleFactor,
    selectionLogical.right * scaleFactor,
    selectionLogical.bottom * scaleFactor,
  );
  return scaled.intersect(full);
}

/// Composites [frozen] (native pixels) + [drawables] (logical coords, scaled by
/// [scaleFactor]) and crops to [selectionLogical] (null = whole display).
/// Returns PNG bytes. Runs on the platform thread (uses dart:ui).
Future<Uint8List> compositeAndCrop({
  required ui.Image frozen,
  required List<Drawable> drawables,
  required double scaleFactor,
  required Size logicalSize,
  required Rect? selectionLogical,
}) async {
  final crop = nativeCropRect(
    selectionLogical: selectionLogical,
    logicalSize: logicalSize,
    scaleFactor: scaleFactor,
  );
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  // Translate so the crop's top-left becomes the output origin.
  canvas.translate(-crop.left, -crop.top);
  // Layer 1: frozen image at native pixels (1:1).
  canvas.drawImage(frozen, ui.Offset.zero, ui.Paint());
  // Pre-compute the whole-frame blur / pixelate once (only if used) so the
  // region drawables can just mask them — same path as on-screen.
  final blurredFull = drawables.any((d) => d is BlurDrawable)
      ? await blurWhole(frozen, kBlurSigmaLogical * scaleFactor)
      : null;
  final pixelatedFull = drawables.any((d) => d is PixelateDrawable)
      ? await pixelateWhole(frozen, kPixelCellNative)
      : null;
  // Layer 2: drawables, scaled logical->native. Paste-image carries its own
  // bitmap; blur/pixelate mask the pre-computed whole-frame images.
  canvas.save();
  canvas.scale(scaleFactor);
  DrawablePainter(
    drawables: drawables,
    selectedIndex: null,
    blurredFull: blurredFull,
    pixelatedFull: pixelatedFull,
  ).paint(canvas, logicalSize);
  canvas.restore();
  final picture = recorder.endRecording();
  final outW = crop.width.round();
  final outH = crop.height.round();
  final img = await picture.toImage(outW, outH);
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}
