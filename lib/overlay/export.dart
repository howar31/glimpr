import 'dart:ui' as ui;
import 'dart:ui' show Rect, Size;
import '../capture/capture_kind.dart';
import '../capture/captured_display.dart';
import '../editor/composite.dart';
import '../editor/decoration.dart';
import '../editor/drawable.dart';
import '../output/deliver.dart';
import '../output/filename.dart';
import '../settings/settings.dart';

/// Composites [frozenImage] (native pixels) + [drawables] (logical coords),
/// crops to [selectionLogical] (null = whole display), encodes ONCE in the
/// format from [cap], then delivers per [cap] (file save + clipboard, each
/// toggleable). The shutter / completion sounds are orchestrated by the caller,
/// so deliverCapture's own sound leg is suppressed here. Off the freeze path:
/// compositing + encoding happen here, on commit.
Future<DeliveryResult> exportAnnotated({
  required CapturedDisplay display,
  required ui.Image frozenImage,
  required List<Drawable> drawables,
  required Rect? selectionLogical,
  required CaptureSettings cap,
  required CaptureKind kind,
  ui.Image? windowMask,
  String? windowTitle,
  String? appName,
}) async {
  // Opt-in decoration for this scenario (null = plain, byte-identical output).
  // The appearance is scaled to the display so it looks the same at any DPI.
  final decoration = cap.decorateFor(kind)
      ? DecorationStyle.scaled(display.scaleFactor)
      : null;
  final bytes = await compositeAndCrop(
    frozen: frozenImage,
    drawables: drawables,
    scaleFactor: display.scaleFactor,
    logicalSize: Size(display.width, display.height),
    selectionLogical: selectionLogical,
    jpeg: cap.isJpeg,
    jpegQuality: cap.jpegQuality,
    decoration: decoration,
    decorationJpegFill: ui.Color(cap.decorationJpegFill),
    // A window snap masks the cropped composite to the window's real shape; the
    // decoration shadow then follows that silhouette.
    windowMask: windowMask,
    decorationShapeFromAlpha: windowMask != null,
  );
  return deliverCapture(
    pngBytes: bytes,
    saveDir: cap.saveDir,
    fileName: buildScreenshotName(
      template: cap.filenameTemplate,
      t: DateTime.now(),
      windowTitle: windowTitle,
      appName: appName,
      ext: cap.fileExtension,
    ),
    soundFn: () async {},
    saveToFile: cap.saveToFile,
    copyToClipboard: cap.copyToClipboard,
  );
}

/// Deliver a natively-captured window image (already alpha-shaped, real rounded
/// corners) — for the direct "Capture Window" mode. No crop, no annotations;
/// decoration (if enabled for [kind]) follows the real silhouette.
Future<DeliveryResult> exportWindowImage({
  required ui.Image windowImage,
  required double scaleFactor,
  required CaptureSettings cap,
  required CaptureKind kind,
  String? windowTitle,
  String? appName,
}) async {
  final decoration = cap.decorateFor(kind)
      ? DecorationStyle.scaled(scaleFactor)
      : null;
  final bytes = await compositeAndCrop(
    frozen: windowImage,
    drawables: const [],
    scaleFactor: scaleFactor,
    logicalSize: Size(
      windowImage.width / scaleFactor,
      windowImage.height / scaleFactor,
    ),
    selectionLogical: null,
    jpeg: cap.isJpeg,
    jpegQuality: cap.jpegQuality,
    decoration: decoration,
    decorationJpegFill: ui.Color(cap.decorationJpegFill),
    decorationShapeFromAlpha: true,
  );
  return deliverCapture(
    pngBytes: bytes,
    saveDir: cap.saveDir,
    fileName: buildScreenshotName(
      template: cap.filenameTemplate,
      t: DateTime.now(),
      windowTitle: windowTitle,
      appName: appName,
      ext: cap.fileExtension,
    ),
    soundFn: () async {},
    saveToFile: cap.saveToFile,
    copyToClipboard: cap.copyToClipboard,
  );
}
