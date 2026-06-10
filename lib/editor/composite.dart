import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as imglib;
import 'decoration.dart';
import 'draw_style.dart';
import 'encode_bridge.dart';
import 'drawable.dart';
import 'drawable_painter.dart';
import 'raster.dart';
import 'spotlight.dart';

/// A logical rect scaled to native pixels.
Rect _nativeRect(Rect r, double s) =>
    Rect.fromLTRB(r.left * s, r.top * s, r.right * s, r.bottom * s);

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
  // Region-local blur / pixelate: rasterise each region over its OWN pixels at its
  // strength (no whole-frame), keyed by drawable so the painter looks it up.
  final effects = <Drawable, ui.Image>{};
  for (final d in drawables) {
    if (d is BlurDrawable) {
      effects[d] = await blurRegion(
        frozen,
        _nativeRect(d.rect, scaleFactor),
        blurSigmaNative(d.style.strength, scaleFactor),
      );
    } else if (d is PixelateDrawable) {
      effects[d] = await pixelateRegion(
        frozen,
        _nativeRect(d.rect, scaleFactor),
        pixelateCellNative(d.style.strength),
      );
    }
  }
  // Spotlight layer: ONE full-canvas blur/pixelate of the base image (the live
  // canvas shows the same via the effect cache). Null when no spotlight wants
  // an effect -> the painter renders the layer dim-only / not at all.
  ui.Image? spotlightImg;
  final layer = spotlightLayerStyle(drawables); // the layer-carrying DrawStyle
  if (layer != null && layer.spotlightEffect != SpotlightEffect.none) {
    final fullNative = Rect.fromLTWH(
        0, 0, frozen.width.toDouble(), frozen.height.toDouble());
    spotlightImg = layer.spotlightEffect == SpotlightEffect.blur
        ? await blurRegion(
            frozen, fullNative, blurSigmaNative(layer.strength, scaleFactor))
        : await pixelateRegion(
            frozen, fullNative, pixelateCellNative(layer.strength));
  }
  // Layer 2: drawables, scaled logical->native. Paste-image carries its own
  // bitmap; blur/pixelate draw their pre-rasterised region images.
  canvas.save();
  canvas.scale(scaleFactor);
  DrawablePainter(
    drawables: drawables,
    effectImage: (d) => effects[d],
    baseImage: frozen,
    baseScale: scaleFactor,
    spotlightImage: spotlightImg,
  ).paint(canvas, logicalSize);
  canvas.restore();
  final picture = recorder.endRecording();
  final outW = crop.width.round();
  final outH = crop.height.round();
  final cropped = await picture.toImage(outW, outH);
  picture.dispose();
  // The per-region blur/pixelate images are now rasterised into `cropped`;
  // release their native memory rather than waiting for GC finalizers.
  for (final img in effects.values) {
    img.dispose();
  }
  spotlightImg?.dispose();

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
    // dart:ui can only encode PNG; for JPEG pull the raw RGBA and encode
    // NATIVELY (ImageIO) — the pure-Dart image-package encoder took seconds
    // for a 5K frame. It stays as the fallback when the channel is missing
    // (unit tests, future hosts without the handler).
    final raw = await output.toByteData(format: ui.ImageByteFormat.rawRgba);
    output.dispose();
    final rgba = raw!.buffer.asUint8List();
    final native = await encodeJpegNative(rgba, ow, oh, jpegQuality);
    if (native != null) return native;
    final encoded = imglib.encodeJpg(
      imglib.Image.fromBytes(
        width: ow,
        height: oh,
        bytes: rgba.buffer,
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
