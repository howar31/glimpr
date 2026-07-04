import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui' show Offset, Rect, Size;
import '../capture/capture_bridge.dart';
import '../capture/capture_kind.dart';
import '../capture/captured_display.dart';
import '../editor/composite.dart';
import '../editor/decoration.dart';
import '../editor/drawable.dart';
import '../image_editor/recent_images.dart';
import '../output/flow.dart';
import '../output/output_naming.dart';
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
  // ⌘⌥5 capture-to-pin session runs {pin} only). Null = cap.flow.
  Set<FlowAction>? flowOverride,
  // The natively-composited HDR rendition (annotations included), written as
  // a same-basename sibling beside the saved SDR file. Produced by the
  // overlay's HDR leg (encodeHdrRegion) when the freeze retained an HDR base.
  Uint8List? hdrBytes,
  String? hdrExt,
}) async {
  final actions = normalizeFlow(flowOverride ?? cap.flow, forCapture: true);
  // Opt-in decoration for this scenario (null = plain, byte-identical output).
  // The appearance is scaled to the display so it looks the same at any DPI.
  // The pin leg always consumes the undecorated capture: a pin-only flow
  // skips decoration entirely; alongside other legs a second plain rendition
  // is composited for it below.
  final plan = decorationPlan(
    decorationEnabled: cap.decorateFor(kind),
    actions: actions,
  );
  final decoration =
      plan.decorate ? DecorationStyle.scaled(display.scaleFactor) : null;
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
  Uint8List? pinBytes;
  if (plan.needsPlainForPin) {
    pinBytes = await compositeAndCrop(
      frozen: frozenImage,
      drawables: drawables,
      scaleFactor: display.scaleFactor,
      logicalSize: Size(display.width, display.height),
      selectionLogical: selectionLogical,
      jpeg: cap.isJpeg,
      jpegQuality: cap.jpegQuality,
      windowMask: windowMask,
      cursorImage: cursorImage,
      cursorTopLeftNative: cursorTopLeftNative,
    );
  }
  // Pin-in-place: the captured region's GLOBAL top-left logical rect (whole
  // display when no selection). The pin leg closes over it; other legs ignore.
  final sel = selectionLogical ??
      Rect.fromLTWH(0, 0, display.width, display.height);
  final pinRect = sel.shift(Offset(display.left, display.top));
  final naming = await resolveCaptureNaming(
    cap: cap,
    ext: cap.fileExtension,
    windowTitle: windowTitle,
    appName: appName,
  );
  return runFlow(
    actions: actions,
    bytes: bytes,
    pinBytes: pinBytes,
    saveDir: naming.dir,
    fileName: naming.fileName,
    soundFn: () async {},
    pinFn: (p) => CaptureBridge.pinImage(p, globalRect: pinRect),
    recordRecentFn: recordRecentCapture,
    hdrBytes: hdrBytes,
    hdrExt: hdrExt,
  );
}

/// Deliver a natively-encoded direct capture. The bytes are ALWAYS final — no
/// annotations, and opt-in decoration is applied natively inside captureRegion
/// (the captured CGImage is wrapped before encoding) — so this is a pure
/// delivery: straight to the flow, no codec pass. [kind] is retained for the
/// signature symmetry with the other delivery entry points.
Future<FlowResult> deliverEncodedCapture({
  required RegionCapture capture,
  required CaptureSettings cap,
  required CaptureKind kind,
  String? windowTitle,
  String? appName,
}) async {
  final bytes = capture.bytes;
  // Pin-in-place: the captured rect's GLOBAL top-left logical position.
  final pinRect = capture.rect.shift(capture.displayOrigin);
  final naming = await resolveCaptureNaming(
    cap: cap,
    ext: cap.fileExtension,
    windowTitle: windowTitle,
    appName: appName,
  );
  return runFlow(
    actions: normalizeFlow(cap.flow, forCapture: true),
    bytes: bytes,
    // The undecorated sibling (when the capture was decorated): the pin leg
    // always shows the plain capture, which also keeps pin-in-place aligned.
    pinBytes: capture.plainBytes,
    saveDir: naming.dir,
    fileName: naming.fileName,
    soundFn: () async {},
    pinFn: (p) => CaptureBridge.pinImage(p, globalRect: pinRect),
    recordRecentFn: recordRecentCapture,
    // Dual-output HDR: written as a same-basename sibling beside the saved
    // SDR file (skipped when the flow has no save leg).
    hdrBytes: capture.hdrBytes,
    hdrExt: capture.hdrExt,
    // Windows: the native capture already wrote the clipboard (alsoCopy).
    preCopied: capture.copiedNative,
  );
}

/// Record a capture-flow save into the shared recent-images store (same
/// NSUserDefaults list the editor owns), then nudge the editor engine to
/// refresh its landing gallery + the menu-bar "Open Recent" submenu.
Future<void> recordRecentCapture(String path) async {
  await RecentImagesStore(Settings.instance.store).add(path);
  try {
    await CaptureBridge.notifyRecentChanged();
  } catch (_) {
    // Channel unavailable (tests) — the store write alone still counts.
  }
}

/// Deliver a natively-captured window image — the direct "Capture Window" mode.
/// The [bytes] are FINAL (real alpha-shaped, decoration applied natively when
/// enabled): no crop, no annotations, no codec pass — a pure delivery. No
/// global origin is available on this path, so its pin leg falls back to
/// centered (the runFlow default).
Future<FlowResult> deliverWindowBytes({
  required Uint8List bytes,
  required CaptureSettings cap,
  String? windowTitle,
  String? appName,
  // The undecorated sibling rendition for the flow's pin leg (alsoPlain).
  Uint8List? pinBytes,
  // Dual-output HDR rendition (undecorated) + extension, when requested and
  // the window's display is HDR.
  Uint8List? hdrBytes,
  String? hdrExt,
  // Windows: the native capture already wrote the clipboard (alsoCopy).
  bool preCopied = false,
}) async {
  final naming = await resolveCaptureNaming(
    cap: cap,
    ext: cap.fileExtension,
    windowTitle: windowTitle,
    appName: appName,
  );
  return runFlow(
    actions: normalizeFlow(cap.flow, forCapture: true),
    bytes: bytes,
    pinBytes: pinBytes,
    saveDir: naming.dir,
    fileName: naming.fileName,
    soundFn: () async {},
    recordRecentFn: recordRecentCapture,
    hdrBytes: hdrBytes,
    hdrExt: hdrExt,
    preCopied: preCopied,
  );
}
