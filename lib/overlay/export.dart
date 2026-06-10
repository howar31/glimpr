import 'dart:ui' as ui;
import 'dart:ui' show Offset, Rect, Size;
import '../capture/capture_bridge.dart';
import '../capture/capture_kind.dart';
import '../capture/captured_display.dart';
import '../editor/composite.dart';
import '../editor/decoration.dart';
import '../editor/drawable.dart';
import '../output/filename.dart';
import '../output/flow.dart';
import '../settings/settings.dart';

/// Composites [frozenImage] (native pixels) + [drawables] (logical coords),
/// crops to [selectionLogical] (null = whole display), encodes ONCE in the
/// format from [cap], then runs the configured after-capture flow ([cap.flow]:
/// save / copy / copy-path / show-in-Finder / open-in-editor). The shutter /
/// completion sounds are orchestrated by the caller, so the flow's sound leg
/// is suppressed here. Off the freeze path: compositing + encoding happen
/// here, on commit.
Future<FlowResult> exportAnnotated({
  required CapturedDisplay display,
  required ui.Image frozenImage,
  required List<Drawable> drawables,
  required Rect? selectionLogical,
  required CaptureSettings cap,
  required CaptureKind kind,
  ui.Image? windowMask,
  ui.Image? cursorImage,
  ui.Offset? cursorTopLeftNative,
  String? windowTitle,
  String? appName,
  // Replaces the configured after-capture flow for this export (e.g. the
  // ⌘⌥7 capture-to-pin session runs {pin} only). Null = cap.flow.
  Set<FlowAction>? flowOverride,
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
    cursorImage: cursorImage,
    cursorTopLeftNative: cursorTopLeftNative,
  );
  // Pin-in-place: the captured region's GLOBAL top-left logical rect (whole
  // display when no selection). The pin leg closes over it; other legs ignore.
  final sel = selectionLogical ??
      Rect.fromLTWH(0, 0, display.width, display.height);
  final pinRect = sel.shift(Offset(display.left, display.top));
  return runFlow(
    actions: normalizeFlow(flowOverride ?? cap.flow, forCapture: true),
    bytes: bytes,
    saveDir: cap.saveDir,
    fileName: buildScreenshotName(
      template: cap.filenameTemplate,
      t: DateTime.now(),
      windowTitle: windowTitle,
      appName: appName,
      ext: cap.fileExtension,
    ),
    soundFn: () async {},
    pinFn: (p) => CaptureBridge.pinImage(p, globalRect: pinRect),
  );
}

/// Deliver a natively-captured window image (already alpha-shaped, real rounded
/// corners) — for the direct "Capture Window" mode. No crop, no annotations;
/// decoration (if enabled for [kind]) follows the real silhouette. No global
/// origin is available on this path, so its pin leg falls back to centered
/// (the runFlow default).
Future<FlowResult> exportWindowImage({
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
  return runFlow(
    actions: normalizeFlow(cap.flow, forCapture: true),
    bytes: bytes,
    saveDir: cap.saveDir,
    fileName: buildScreenshotName(
      template: cap.filenameTemplate,
      t: DateTime.now(),
      windowTitle: windowTitle,
      appName: appName,
      ext: cap.fileExtension,
    ),
    soundFn: () async {},
  );
}
