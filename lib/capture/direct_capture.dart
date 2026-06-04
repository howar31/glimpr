import 'dart:ui' as ui;
import 'dart:ui' show Rect;
import '../output/deliver.dart';
import '../output/sounds.dart';
import '../overlay/export.dart';
import '../settings/settings.dart';
import 'capture_bridge.dart';
import 'captured_display.dart';
import 'last_region.dart';

/// What a direct capture should output: a [display] frame, an optional crop
/// [selectionLogical] (null = whole display), and an optional window name for
/// the filename token.
class CaptureTarget {
  const CaptureTarget({
    required this.display,
    this.selectionLogical,
    this.windowTitle,
    this.appName,
  });
  final CapturedDisplay display;
  final Rect? selectionLogical;
  final String? windowTitle;
  final String? appName;
}

/// The display under the cursor (whole display). Null when no frames.
CaptureTarget? resolveScreenTarget(List<CapturedDisplay> frames) {
  if (frames.isEmpty) return null;
  final d = frames.firstWhere((f) => f.isCursorDisplay, orElse: () => frames.first);
  return CaptureTarget(display: d);
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
      return CaptureTarget(display: f, selectionLogical: region.rect);
    }
  }
  return null;
}

/// Decodes the chosen frame and delivers it with no annotations.
Future<DeliveryResult> _defaultDeliver(CaptureTarget t, CaptureSettings cap) async {
  final codec = await ui.instantiateImageCodec(t.display.pngBytes);
  final image = (await codec.getNextFrame()).image;
  codec.dispose();
  try {
    return await exportAnnotated(
      display: t.display,
      frozenImage: image,
      drawables: const [],
      selectionLogical: t.selectionLogical,
      cap: cap,
      windowTitle: t.windowTitle,
      appName: t.appName,
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
    Future<List<CapturedDisplay>> Function()? captureFrames,
    Future<FocusedWindowInfo?> Function()? focusedWindow,
    Settings? settings,
    LastRegionStore? regionStore,
    Future<DeliveryResult> Function(CaptureTarget, CaptureSettings)? deliver,
    void Function()? shutter,
    void Function()? complete,
    void Function(String)? showError,
  })  : _captureFrames = captureFrames ?? CaptureBridge().captureFrames,
        _focusedWindow = focusedWindow ?? CaptureBridge().focusedWindow,
        _settings = settings ?? Settings.instance,
        _regionStore = regionStore ?? LastRegionStore(Settings.instance.store),
        _deliver = deliver ?? _defaultDeliver,
        _shutter = shutter ?? (() => playShutter()),
        _complete = complete ?? (() => playComplete()),
        _showError = showError ?? ((m) => CaptureBridge().showError(m));

  final Future<List<CapturedDisplay>> Function() _captureFrames;
  final Future<FocusedWindowInfo?> Function() _focusedWindow;
  final Settings _settings;
  final LastRegionStore _regionStore;
  final Future<DeliveryResult> Function(CaptureTarget, CaptureSettings) _deliver;
  final void Function() _shutter;
  final void Function() _complete;
  final void Function(String) _showError;

  Future<void> screen() =>
      _run((frames) async => resolveScreenTarget(frames));

  Future<void> window() => _run(
      (frames) async => resolveWindowTarget(frames, await _focusedWindow()));

  Future<void> lastRegion() => _run(
      (frames) async => resolveLastRegionTarget(frames, await _regionStore.load()));

  Future<void> _run(
      Future<CaptureTarget?> Function(List<CapturedDisplay>) pick) async {
    final cap = await _settings.loadCapture();
    final List<CapturedDisplay> frames;
    try {
      frames = await _captureFrames();
    } catch (e) {
      _showError('Capture failed: $e');
      return;
    }
    final target = await pick(frames);
    if (target == null) return; // silent no-op (empty last-region / gone display)

    if (cap.shutterSound) _shutter();
    try {
      final result = await _deliver(target, cap);
      final ok = (!cap.saveToFile || result.savedOk) &&
          (!cap.copyToClipboard || result.copiedToClipboard);
      if (ok) {
        if (cap.completionSound) _complete();
      } else {
        _showError('Capture failed');
      }
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
