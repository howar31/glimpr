import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as imglib;
import 'decoration.dart';
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
  bool jpeg = false,
  int jpegQuality = 90,
  DecorationStyle? decoration,
  ui.Color decorationJpegFill = const ui.Color(0xFFFFFFFF),
  ui.Image? windowMask,
  bool decorationShapeFromAlpha = false,
  ui.Image? cursorImage,
  ui.Offset? cursorTopLeftNative,
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
  // Mouse pointer (overlay, when the toggle is on): part of the BASE — drawn over
  // the frozen pixels and UNDER the annotations, at its native top-left.
  if (cursorImage != null && cursorTopLeftNative != null) {
    canvas.drawImage(cursorImage, cursorTopLeftNative, ui.Paint());
  }
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
    blurredFull: blurredFull,
    pixelatedFull: pixelatedFull,
  ).paint(canvas, logicalSize);
  canvas.restore();
  final picture = recorder.endRecording();
  final outW = crop.width.round();
  final outH = crop.height.round();
  final cropped = await picture.toImage(outW, outH);
  picture.dispose();
  // The whole-frame blur/pixelate (if any) are now rasterised into `cropped`;
  // release their native memory rather than waiting for GC finalizers.
  blurredFull?.dispose();
  pixelatedFull?.dispose();

  // Opt-in decoration: wrap the cropped content in margin + rounded corners +
  // drop shadow. JPEG (no alpha) fills the transparent region with the fill
  // colour; PNG keeps it transparent. The output is larger than the crop, so the
  // encoder uses the decorated image's own dimensions below.
  ui.Image output = cropped;
  // Window-shape mask: keep the cropped pixels only where the window's real
  // alpha is opaque (dstIn) -> faithful rounded corners. Only the mask's alpha
  // matters; it is scaled to the crop so a ≤1px geometry difference leaves no seam.
  if (windowMask != null) {
    final rec = ui.PictureRecorder();
    final cv = ui.Canvas(rec);
    cv.drawImage(output, ui.Offset.zero, ui.Paint());
    cv.drawImageRect(
      windowMask,
      ui.Rect.fromLTWH(
        0,
        0,
        windowMask.width.toDouble(),
        windowMask.height.toDouble(),
      ),
      ui.Rect.fromLTWH(0, 0, output.width.toDouble(), output.height.toDouble()),
      ui.Paint()..blendMode = ui.BlendMode.dstIn,
    );
    final pic = rec.endRecording();
    final masked = await pic.toImage(output.width, output.height);
    pic.dispose();
    output.dispose();
    output = masked;
  }
  if (decoration != null) {
    final decorated = await applyDecoration(
      output,
      decoration,
      fill: jpeg ? decorationJpegFill : null,
      shapeFromContentAlpha: decorationShapeFromAlpha,
    );
    output.dispose(); // the un-decorated intermediate (cropped or masked)
    output = decorated;
  }
  final ow = output.width;
  final oh = output.height;

  if (jpeg) {
    // dart:ui can only encode PNG; for JPEG pull the raw RGBA and encode via
    // the image package. This runs on the background path (overlay already
    // hidden), so the extra encode cost is off the user-facing hot path.
    final raw = await output.toByteData(format: ui.ImageByteFormat.rawRgba);
    output.dispose();
    final encoded = imglib.encodeJpg(
      imglib.Image.fromBytes(
        width: ow,
        height: oh,
        bytes: raw!.buffer,
        numChannels: 4,
        order: imglib.ChannelOrder.rgba,
      ),
      quality: jpegQuality,
    );
    return Uint8List.fromList(encoded);
  }
  final data = await output.toByteData(format: ui.ImageByteFormat.png);
  output.dispose();
  return data!.buffer.asUint8List();
}
