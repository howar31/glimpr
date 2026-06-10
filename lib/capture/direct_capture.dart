import 'dart:async';
import 'dart:ui' as ui;
import 'dart:ui' show Rect;
import '../output/flow.dart';
import '../output/sounds.dart';
import '../overlay/export.dart';
import '../settings/settings.dart';
import 'capture_bridge.dart';
import 'capture_kind.dart';
import 'captured_display.dart';
import 'last_region.dart';

/// What a direct capture should output: a [display] frame, an optional crop
/// [selectionLogical] (null = whole display), and an optional window name for
/// the filename token.
class CaptureTarget {
  const CaptureTarget({
    required this.display,
    required this.kind,
    this.selectionLogical,
    this.windowTitle,
    this.appName,
  });
  final CapturedDisplay display;
  final CaptureKind kind;
  final Rect? selectionLogical;
  final String? windowTitle;
  final String? appName;
}

/// Filename labels substituted for the {window}/{app} tokens when a capture has
/// no real window context, so the saved name is meaningful instead of blank.
const kDisplayCaptureLabel = 'DISPLAY';
const kLastRegionCaptureLabel = 'LAST';

/// The display under the cursor (whole display). Null when no frames. Labelled
/// "DISPLAY" so the filename's window/app tokens read sensibly.
CaptureTarget? resolveScreenTarget(List<CapturedDisplay> frames) {
  if (frames.isEmpty) return null;
  final d = frames.firstWhere((f) => f.isCursorDisplay, orElse: () => frames.first);
  return CaptureTarget(
      display: d,
      kind: CaptureKind.display,
      windowTitle: kDisplayCaptureLabel,
      appName: kDisplayCaptureLabel);
}

/// The focused window's rect on its display. Falls back to [resolveScreenTarget]
/// when there is no focused window or its display was not captured.
CaptureTarget? resolveWindowTarget(
    List<CapturedDisplay> frames, FocusedWindowInfo? window) {
  if (window == null) return resolveScreenTarget(frames);
  for (final f in frames) {
    if (f.displayId == window.displayId) {
      return CaptureTarget(
        display: f,
        kind: CaptureKind.focusedWindow,
        selectionLogical: window.rect,
        windowTitle: window.title,
        appName: window.app,
      );
    }
  }
  return resolveScreenTarget(frames);
}

/// The stored region's rect on its display. Null (no-op) when nothing is stored
/// or the stored display is no longer present.
CaptureTarget? resolveLastRegionTarget(
    List<CapturedDisplay> frames, LastRegion? region) {
  if (region == null) return null;
  for (final f in frames) {
    if (f.displayId == region.displayId) {
      return CaptureTarget(
          display: f,
          kind: CaptureKind.lastRegion,
          selectionLogical: region.rect,
          windowTitle: kLastRegionCaptureLabel,
          appName: kLastRegionCaptureLabel);
    }
  }
  return null;
}

/// Decodes the chosen frame and delivers it with no annotations.
Future<FlowResult> _defaultDeliver(CaptureTarget t, CaptureSettings cap) async {
  // Raw BGRA pixels -> ui.Image (no codec). Interim until the native
  // single-target captureRegion replaces this whole leg.
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    t.display.rawBytes, t.display.pixelWidth, t.display.pixelHeight,
    ui.PixelFormat.bgra8888, completer.complete, rowBytes: t.display.rowBytes,
  );
  final ui.Image image = await completer.future;
  try {
    return await exportAnnotated(
      display: t.display,
      frozenImage: image,
      drawables: const [],
      selectionLogical: t.selectionLogical,
      cap: cap,
      kind: t.kind,
      windowTitle: t.windowTitle,
      appName: t.appName,
    );
  } finally {
    image.dispose();
  }
}

/// Decodes a natively-captured window image (real alpha / rounded corners) and
/// delivers it directly — the "Capture Window" path. No display crop.
Future<FlowResult> _defaultDeliverWindow(
    WindowImage wi, CaptureSettings cap, FocusedWindowInfo info) async {
  final codec = await ui.instantiateImageCodec(wi.pngBytes);
  final ui.Image image;
  try {
    image = (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
  try {
    return await exportWindowImage(
      windowImage: image,
      scaleFactor: wi.scale,
      cap: cap,
      kind: CaptureKind.focusedWindow,
      windowTitle: info.title.isEmpty ? null : info.title,
      appName: info.app.isEmpty ? null : info.app,
    );
  } finally {
    image.dispose();
  }
}

/// Orchestrates the three non-interactive capture modes in the control engine.
/// Collaborators are injectable so the control flow is unit-tested without the
/// native channel or a real image.
class DirectCapture {
  DirectCapture({
    Future<List<CapturedDisplay>> Function({bool showsCursor})? captureFrames,
    Future<FocusedWindowInfo?> Function()? focusedWindow,
    Future<WindowImage?> Function(int, {bool showsCursor})? captureWindowImage,
    Settings? settings,
    LastRegionStore? regionStore,
    Future<FlowResult> Function(CaptureTarget, CaptureSettings)? deliver,
    Future<FlowResult> Function(WindowImage, CaptureSettings, FocusedWindowInfo)?
        deliverWindow,
    void Function()? shutter,
    void Function()? complete,
    void Function(String)? showError,
    void Function(String)? perfMark,
  })  : _captureFrames = captureFrames ?? CaptureBridge().captureFrames,
        _focusedWindow = focusedWindow ?? CaptureBridge().focusedWindow,
        _captureWindowImage =
            captureWindowImage ?? CaptureBridge().captureWindowImage,
        _settings = settings ?? Settings.instance,
        _regionStore = regionStore ?? LastRegionStore(Settings.instance.store),
        _deliver = deliver ?? _defaultDeliver,
        _deliverWindow = deliverWindow ?? _defaultDeliverWindow,
        _shutter = shutter ?? (() => playShutter()),
        _complete = complete ?? (() => playComplete()),
        _showError = showError ?? ((m) => CaptureBridge().showError(m)),
        _perfMark = perfMark ?? ((label) => CaptureBridge.perfMark(label));

  final Future<List<CapturedDisplay>> Function({bool showsCursor}) _captureFrames;
  final Future<FocusedWindowInfo?> Function() _focusedWindow;
  final Future<WindowImage?> Function(int, {bool showsCursor}) _captureWindowImage;
  final Settings _settings;
  final LastRegionStore _regionStore;
  final Future<FlowResult> Function(CaptureTarget, CaptureSettings) _deliver;
  final Future<FlowResult> Function(
      WindowImage, CaptureSettings, FocusedWindowInfo) _deliverWindow;
  final void Function() _shutter;
  final void Function() _complete;
  final void Function(String) _showError;
  final void Function(String) _perfMark;

  Future<void> screen() =>
      _run((frames) async => resolveScreenTarget(frames));

  /// Capture the focused window with its REAL shape (rounded corners) via the
  /// native per-window path; on any miss (no focused window, no window id, or a
  /// failed per-window capture) fall back to the previous rectangular crop.
  Future<void> window() async {
    final info = await _focusedWindow();
    if (info?.windowId != null) {
      final cap = await _settings.loadCapture();
      WindowImage? wi;
      try {
        wi = await _captureWindowImage(
          info!.windowId!,
          showsCursor: cap.captureCursor,
        );
      } catch (_) {
        wi = null; // fall through to the rectangular crop
      }
      if (wi != null) {
        if (cap.shutterSound) _shutter();
        try {
          final result = await _deliverWindow(wi, cap, info!);
          final ok = (!cap.flow.contains(FlowAction.save) || result.savedOk) &&
              (!cap.flow.contains(FlowAction.copy) || result.copiedToClipboard);
          if (ok) {
            if (cap.completionSound) _complete();
          } else {
            _showError('Capture failed');
          }
          // kind=window marks the real-alpha leg; the rectangular fallback
          // below reports kind=focusedWindow through _run's mark instead.
          _perfMark('directDelivered ok=$ok kind=window');
        } catch (e) {
          _showError('Capture failed: $e');
        }
        // Record the window's rect so "Capture Last Region" can repeat it.
        await _regionStore.save(
            LastRegion(displayId: info!.displayId, rect: info.rect));
        return;
      }
    }
    // Fallback: the original rectangular window crop (whole display if there is
    // no focused window) — real corners unavailable, but capture still works.
    await _run((frames) async => resolveWindowTarget(frames, info));
  }

  Future<void> lastRegion() => _run(
      (frames) async => resolveLastRegionTarget(frames, await _regionStore.load()));

  Future<void> _run(
      Future<CaptureTarget?> Function(List<CapturedDisplay>) pick) async {
    final cap = await _settings.loadCapture();
    final List<CapturedDisplay> frames;
    try {
      frames = await _captureFrames(showsCursor: cap.captureCursor);
    } catch (e) {
      _showError('Capture failed: $e');
      return;
    }
    final target = await pick(frames);
    if (target == null) return; // silent no-op (empty last-region / gone display)

    if (cap.shutterSound) _shutter();
    try {
      final result = await _deliver(target, cap);
      final ok = (!cap.flow.contains(FlowAction.save) || result.savedOk) &&
          (!cap.flow.contains(FlowAction.copy) || result.copiedToClipboard);
      if (ok) {
        if (cap.completionSound) _complete();
      } else {
        _showError('Capture failed');
      }
      _perfMark('directDelivered ok=$ok kind=${target.kind.name}');
    } catch (e) {
      _showError('Capture failed: $e');
    }
    // Record the final region for the next "Capture Last Region".
    final rect = target.selectionLogical ??
        Rect.fromLTWH(0, 0, target.display.width, target.display.height);
    await _regionStore.save(
        LastRegion(displayId: target.display.displayId, rect: rect));
  }
}
