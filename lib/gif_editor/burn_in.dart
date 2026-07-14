import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart' show Color, Offset, Rect, Size;

import '../editor/draw_style.dart' show SpotlightEffect;
import '../editor/drawable.dart';
import '../editor/drawable_painter.dart';
import '../editor/raster.dart';
import '../editor/spotlight.dart';
import 'frame_store.dart';
import 'gif_document.dart';

/// Default progress-bar look: the app accent, 4 native px along the bottom.
/// The UI passes the live token; this keeps the service theme-free.
const Color kProgressBarColor = Color(0xFF60A5FA);
const int kProgressBarHeightPx = 4;

/// Burn [drawables] into the frames of [range] (empty/null = every frame)
/// and/or draw a playback progress bar onto EVERY frame, producing NEW store
/// entries; returns the replacement frame list (delays preserved).
///
/// This replays the editor's export composite per frame — the same layer
/// recipe as compositeAndCrop (per-frame blur/pixelate region rasters, the
/// spotlight layer, DrawablePainter) at scale 1.0, because a GIF frame's
/// logical canvas IS its pixel grid. It must run on the UI isolate (dart:ui
/// objects cannot cross isolates; toImage rasterizes off-thread), so frames
/// are processed sequentially with awaits between them.
Future<List<GifFrame>> bakeDocument({
  required GifDocument doc,
  required FrameStore store,
  required List<Drawable> drawables,
  Set<int>? range,
  bool progressBar = false,
  Color progressColor = kProgressBarColor,
  int progressHeightPx = kProgressBarHeightPx,
  void Function(int done, int total)? onProgress,
}) async {
  assert(doc.frames.isNotEmpty);
  assert(drawables.isNotEmpty || progressBar, 'nothing to bake');
  final drawAll = range == null || range.isEmpty;
  final totalMs = doc.totalDuration.inMilliseconds;
  final out = <GifFrame>[];
  var elapsedMs = 0;
  var done = 0;
  for (var i = 0; i < doc.frameCount; i++) {
    final frame = doc.frames[i];
    elapsedMs += frame.delayMs;
    final annotate =
        drawables.isNotEmpty && (drawAll || range.contains(i));
    if (!annotate && !progressBar) {
      out.add(frame);
      done++;
      onProgress?.call(done, doc.frameCount);
      continue;
    }
    final w = frame.width;
    final h = frame.height;
    final rgba = await File(store.pathFor(frame.key)).readAsBytes();
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
        rgba, w, h, ui.PixelFormat.rgba8888, completer.complete);
    final base = await completer.future;

    // Region effects + the spotlight layer rasterize against THIS frame's
    // own pixels (compositeAndCrop's recipe at scaleFactor 1.0).
    final effects = <Drawable, ui.Image>{};
    ui.Image? spotlightImg;
    if (annotate) {
      for (final d in drawables) {
        if (d is BlurDrawable) {
          effects[d] = await blurRegion(
              base, d.rect, blurSigmaNative(d.style.strength, 1.0));
        } else if (d is PixelateDrawable) {
          effects[d] = await pixelateRegion(
              base, d.rect, pixelateCellNative(d.style.strength));
        }
      }
      final layer = spotlightLayerStyle(drawables);
      if (layer != null && layer.spotlightEffect != SpotlightEffect.none) {
        final full = Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
        spotlightImg = layer.spotlightEffect == SpotlightEffect.blur
            ? await blurRegion(
                base, full, blurSigmaNative(layer.strength, 1.0))
            : await pixelateRegion(
                base, full, pixelateCellNative(layer.strength));
      }
    }

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImage(base, Offset.zero, ui.Paint());
    if (annotate) {
      DrawablePainter(
        drawables: drawables,
        effectImage: (d) => effects[d],
        baseImage: base,
        baseScale: 1.0,
        spotlightImage: spotlightImg,
      ).paint(canvas, Size(w.toDouble(), h.toDouble()));
    }
    if (progressBar) {
      // Fraction through the END of this frame: the bar completes exactly
      // on the last frame.
      final fraction = totalMs == 0 ? 1.0 : elapsedMs / totalMs;
      final barH = progressHeightPx.clamp(1, h).toDouble();
      canvas.drawRect(
        Rect.fromLTWH(0, h - barH, w * fraction, barH),
        ui.Paint()..color = progressColor,
      );
    }
    final picture = recorder.endRecording();
    final baked = await picture.toImage(w, h);
    picture.dispose();
    for (final img in effects.values) {
      img.dispose();
    }
    spotlightImg?.dispose();
    base.dispose();
    final bytes = await baked.toByteData(format: ui.ImageByteFormat.rawRgba);
    baked.dispose();
    final key = await store.put(
        bytes!.buffer.asUint8List(bytes.offsetInBytes, w * h * 4), w, h);
    out.add(GifFrame(
        key: key, width: w, height: h, delayMs: frame.delayMs));
    done++;
    onProgress?.call(done, doc.frameCount);
  }
  return out;
}
