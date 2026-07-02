import 'dart:typed_data';
import 'dart:ui' as ui;

import 'composite.dart' show nativeCropRect;
import 'draw_style.dart';
import 'drawable.dart';
import 'drawable_painter.dart';
import 'raster.dart';
import 'spotlight.dart';

/// Builds the ordered item list for the native HDR compositor — the second
/// output renderer of the annotated overlay export. The SDR export
/// ([compositeAndCrop]) stays byte-identical; this walks the SAME drawable
/// z-order and splits it into
///   - OVERLAY segments: pure-SDR annotation runs rasterised here (rawRgba at
///     crop size, transparent background), alpha-blended over the HDR base by
///     native, and
///   - EFFECT ops: the base-sampling pieces (blur / pixelate / magnify content
///     / the spotlight layer), which native recomputes from the pristine HDR
///     base so they stay true-HDR.
///
/// Geometry: effect ops are FRAME-space native px (native samples the full
/// retained base, so a blur near the crop edge bleeds correctly, mirroring
/// [blurRegion]'s inflate); overlay segments are CROP-space bitmaps. A magnify
/// callout is three items (under-chrome overlay run, native content op,
/// over-chrome overlay run) so its shadow stays under and its border over the
/// magnified pixels, exactly like [DrawablePainter]'s single-pass order.
///
/// Blend/space contract with native (both platforms): work in EXTENDED sRGB
/// GAMMA encoding so every blend/filter matches the Dart (sRGB) result exactly
/// wherever the base is within SDR range; above SDR white the extended curve
/// takes over (documented deviation for semi-transparent ink over highlights).
Future<List<Map<String, dynamic>>> buildHdrExportItems({
  required List<Drawable> drawables,
  required double scaleFactor,
  required ui.Size logicalSize,
  required ui.Rect? selectionLogical,
  ui.Image? cursorImage,
  ui.Offset? cursorTopLeftNative,
}) async {
  final crop = nativeCropRect(
    selectionLogical: selectionLogical,
    logicalSize: logicalSize,
    scaleFactor: scaleFactor,
  );
  final outW = crop.width.round();
  final outH = crop.height.round();
  final items = <Map<String, dynamic>>[];

  // One overlay segment accumulating painter passes until an effect op flushes
  // it. Passes draw into a single recorder canvas at crop size.
  ui.PictureRecorder? rec;
  ui.Canvas? canvas;
  void ensureSegment() {
    if (rec != null) return;
    rec = ui.PictureRecorder();
    canvas = ui.Canvas(rec!)..translate(-crop.left, -crop.top);
  }

  void paintPass(List<Drawable> run, {MagnifyPart part = MagnifyPart.all}) {
    if (run.isEmpty) return;
    ensureSegment();
    canvas!.save();
    canvas!.scale(scaleFactor);
    DrawablePainter(drawables: run, magnifyPart: part)
        .paint(canvas!, logicalSize);
    canvas!.restore();
  }

  Future<void> flushSegment() async {
    if (rec == null) return;
    final picture = rec!.endRecording();
    rec = null;
    canvas = null;
    final img = await picture.toImage(outW, outH);
    picture.dispose();
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    img.dispose();
    if (data == null) return;
    items.add({
      't': 'overlay',
      'bytes': Uint8List.view(data.buffer),
      'w': outW,
      'h': outH,
    });
  }

  Map<String, dynamic> nativeRectMap(ui.Rect logical) => {
        'x': logical.left * scaleFactor,
        'y': logical.top * scaleFactor,
        'w': logical.width * scaleFactor,
        'h': logical.height * scaleFactor,
      };

  Future<void> emitRun(Iterable<Drawable> run) async {
    var pending = <Drawable>[];
    for (final d in run) {
      if (d is SpotlightDrawable) continue; // holes live in the layer op
      if (d is BlurDrawable || d is PixelateDrawable) {
        paintPass(pending);
        pending = [];
        await flushSegment();
        final isBlur = d is BlurDrawable;
        final rect = d is BlurDrawable ? d.rect : (d as PixelateDrawable).rect;
        items.add({
          't': isBlur ? 'blur' : 'pixelate',
          ...nativeRectMap(rect),
          if (isBlur)
            'sigma': blurSigmaNative(d.style.strength, scaleFactor)
          else
            'cell': pixelateCellNative(d.style.strength),
        });
      } else if (d is MagnifyDrawable) {
        paintPass(pending);
        pending = [];
        // Chrome under the content (shadow + source frame + connectors)…
        paintPass([d], part: MagnifyPart.underChrome);
        await flushSegment();
        items.add({
          't': 'magnify',
          'sx': d.sourceRect.left * scaleFactor,
          'sy': d.sourceRect.top * scaleFactor,
          'sw': d.sourceRect.width * scaleFactor,
          'sh': d.sourceRect.height * scaleFactor,
          'dx': d.destRect.left * scaleFactor,
          'dy': d.destRect.top * scaleFactor,
          'dw': d.destRect.width * scaleFactor,
          'dh': d.destRect.height * scaleFactor,
        });
        paintPass([d], part: MagnifyPart.overChrome);
      } else {
        pending.add(d);
      }
    }
    paintPass(pending);
  }

  // Cursor layer first: part of the base, under every annotation.
  if (cursorImage != null && cursorTopLeftNative != null) {
    ensureSegment();
    canvas!.drawImage(cursorImage, cursorTopLeftNative, ui.Paint());
  }

  final layer = spotlightLayerStyle(drawables);
  if (layer == null) {
    await emitRun(drawables);
  } else {
    // Mirror DrawablePainter.paint's spotlight split: raster regions under,
    // the shared layer, everything else above.
    await emitRun(drawables.where(paintsUnderSpotlight));
    await flushSegment();
    items.add({
      't': 'spotlight',
      'effect': layer.spotlightEffect.name,
      'strength': layer.spotlightEffect == SpotlightEffect.pixelate
          ? pixelateCellNative(layer.strength)
          : blurSigmaNative(layer.strength, scaleFactor),
      'dim': layer.spotlightDim / 100,
      'feather': spotlightSigma(layer.spotlightFeather) * scaleFactor,
      'holes': [
        for (final d in drawables)
          if (d is SpotlightDrawable)
            {
              ...nativeRectMap(d.rect),
              'radius': resolveCornerRadius(d.style.cornerRadius, d.rect) *
                  scaleFactor,
            },
      ],
    });
    await emitRun(drawables.where((d) => !paintsUnderSpotlight(d)));
  }
  await flushSegment();
  return items;
}
