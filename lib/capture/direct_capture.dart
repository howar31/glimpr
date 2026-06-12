import 'dart:typed_data';
import 'dart:ui' show Rect;
import '../editor/decoration.dart';
import '../output/flow.dart';
import '../output/sounds.dart';
import '../overlay/export.dart';
import '../settings/settings.dart';
import 'capture_bridge.dart';
import 'capture_kind.dart';
import 'captured_display.dart';
import 'last_region.dart';

/// Filename labels substituted for the {window}/{app} tokens when a capture has
/// no real window context, so the saved name is meaningful instead of blank.
const kDisplayCaptureLabel = 'DISPLAY';
const kLastRegionCaptureLabel = 'LAST';

/// Deliver a natively-captured window image (real alpha / rounded corners,
/// decoration applied natively) directly — the "Capture Window" path. The
/// [bytes] are FINAL; no decode, composite, or display crop. [pinBytes] is
/// the undecorated sibling for the flow's pin leg, when one was requested.
Future<FlowResult> _defaultDeliverWindow(
    Uint8List bytes, CaptureSettings cap, FocusedWindowInfo info,
    {Uint8List? pinBytes}) async {
  return deliverWindowBytes(
    bytes: bytes,
    cap: cap,
    windowTitle: info.title.isEmpty ? null : info.title,
    appName: info.app.isEmpty ? null : info.app,
    pinBytes: pinBytes,
  );
}

/// Orchestrates the three non-interactive capture modes in the control engine.
/// The image is captured + cropped + encoded NATIVELY ([CaptureBridge.
/// captureRegion]); Dart keeps target resolution, the delivery flow, sounds
/// and the region store. Collaborators are injectable so the control flow is
/// unit-tested without the native channel or a real image.
class DirectCapture {
  DirectCapture({
    Future<RegionCapture?> Function(
            {int? displayId,
            Rect? rect,
            bool showsCursor,
            bool jpeg,
            int jpegQuality,
            Map<String, dynamic>? decoration,
            bool alsoPlain})?
        captureRegion,
    Future<FocusedWindowInfo?> Function()? focusedWindow,
    Future<({Uint8List bytes, Uint8List? plainBytes})?> Function(int,
            {bool showsCursor,
            bool jpeg,
            int jpegQuality,
            Map<String, dynamic>? decoration,
            bool alsoPlain})?
        captureWindowDelivered,
    Settings? settings,
    LastRegionStore? regionStore,
    Future<FlowResult> Function(
            RegionCapture, CaptureSettings, CaptureKind, String?, String?)?
        deliverEncoded,
    Future<FlowResult> Function(Uint8List, CaptureSettings, FocusedWindowInfo,
            {Uint8List? pinBytes})?
        deliverWindow,
    void Function()? shutter,
    void Function()? complete,
    void Function(String)? showError,
    void Function(String)? perfMark,
  })  : _captureRegion = captureRegion ?? CaptureBridge().captureRegion,
        _focusedWindow = focusedWindow ?? CaptureBridge().focusedWindow,
        _captureWindowDelivered =
            captureWindowDelivered ?? CaptureBridge().captureWindowDelivered,
        _settings = settings ?? Settings.instance,
        _regionStore = regionStore ?? LastRegionStore(Settings.instance.store),
        _deliverEncoded = deliverEncoded ??
            ((c, cap, kind, title, app) => deliverEncodedCapture(
                capture: c,
                cap: cap,
                kind: kind,
                windowTitle: title,
                appName: app)),
        _deliverWindow = deliverWindow ?? _defaultDeliverWindow,
        _shutter = shutter ?? (() => playShutter()),
        _complete = complete ?? (() => playComplete()),
        _showError = showError ?? ((m) => CaptureBridge().showError(m)),
        _perfMark = perfMark ?? ((label) => CaptureBridge.perfMark(label));

  final Future<RegionCapture?> Function(
      {int? displayId,
      Rect? rect,
      bool showsCursor,
      bool jpeg,
      int jpegQuality,
      Map<String, dynamic>? decoration,
      bool alsoPlain}) _captureRegion;
  final Future<FocusedWindowInfo?> Function() _focusedWindow;
  final Future<({Uint8List bytes, Uint8List? plainBytes})?> Function(int,
      {bool showsCursor,
      bool jpeg,
      int jpegQuality,
      Map<String, dynamic>? decoration,
      bool alsoPlain}) _captureWindowDelivered;
  final Settings _settings;
  final LastRegionStore _regionStore;
  final Future<FlowResult> Function(
          RegionCapture, CaptureSettings, CaptureKind, String?, String?)
      _deliverEncoded;
  final Future<FlowResult> Function(
      Uint8List, CaptureSettings, FocusedWindowInfo,
      {Uint8List? pinBytes}) _deliverWindow;
  final void Function() _shutter;
  final void Function() _complete;
  final void Function(String) _showError;
  final void Function(String) _perfMark;

  Future<void> screen() => _capture(
      displayId: null,
      rect: null,
      kind: CaptureKind.display,
      windowTitle: kDisplayCaptureLabel,
      appName: kDisplayCaptureLabel);

  /// Capture the focused window with its REAL shape (rounded corners) via the
  /// native per-window path; on any miss (no focused window, no window id, or a
  /// failed per-window capture) fall back to a rectangular crop of its rect.
  Future<void> window() async {
    final info = await _focusedWindow();
    if (info?.windowId != null) {
      final cap = await _settings.loadCapture();
      // Decoration (when enabled) follows the window's real silhouette; applied
      // natively, so the delivered bytes are final. The pin leg always shows
      // the undecorated capture (decorationPlan): a pin-only flow skips
      // decoration; alongside other legs native also returns the plain sibling.
      final plan = decorationPlan(
        decorationEnabled: cap.decorateFor(CaptureKind.focusedWindow),
        actions: normalizeFlow(cap.flow, forCapture: true),
      );
      final decoration = plan.decorate
          ? logicalDecorationSpec(
              fillArgb: cap.isJpeg ? cap.decorationJpegFill : null,
              shapeFromAlpha: true,
            )
          : null;
      ({Uint8List bytes, Uint8List? plainBytes})? delivered;
      try {
        delivered = await _captureWindowDelivered(
          info!.windowId!,
          showsCursor: cap.captureCursor,
          jpeg: cap.isJpeg,
          jpegQuality: cap.jpegQuality,
          decoration: decoration,
          alsoPlain: plan.needsPlainForPin,
        );
      } catch (_) {
        delivered = null; // fall through to the rectangular crop
      }
      if (delivered != null) {
        final bytes = delivered.bytes;
        _perfMark('windowImageReceived bytes=${bytes.length}');
        if (cap.shutterSound) _shutter();
        try {
          final result = await _deliverWindow(bytes, cap, info!,
              pinBytes: delivered.plainBytes);
          final ok = (!cap.flow.contains(FlowAction.save) || result.savedOk) &&
              (!cap.flow.contains(FlowAction.copy) || result.copiedToClipboard);
          if (ok) {
            if (cap.completionSound) _complete();
          } else {
            _showError('Capture failed');
          }
          // kind=window marks the real-alpha leg; the rectangular fallback
          // below reports kind=focusedWindow through _capture's mark instead.
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
    // Fallback: a rectangular crop of the focused window's rect (whole cursor
    // display when there is no focused window) — real corners unavailable,
    // but capture still works.
    if (info == null) {
      await screen();
      return;
    }
    final handled = await _capture(
      displayId: info.displayId,
      rect: info.rect,
      kind: CaptureKind.focusedWindow,
      windowTitle: info.title.isEmpty ? null : info.title,
      appName: info.app.isEmpty ? null : info.app,
    );
    // The focused window's display vanished between resolve and capture ->
    // capture the cursor display instead (parity with the old frame-based
    // fallback).
    if (!handled) await screen();
  }

  Future<void> lastRegion() async {
    final region = await _regionStore.load();
    if (region == null) return; // nothing stored -> silent no-op
    await _capture(
      displayId: region.displayId,
      rect: region.rect,
      kind: CaptureKind.lastRegion,
      windowTitle: kLastRegionCaptureLabel,
      appName: kLastRegionCaptureLabel,
      silentOnMissingDisplay: true,
    );
  }

  /// Native capture + deliver. Returns false ONLY when the requested display
  /// is gone and [silentOnMissingDisplay] is false (caller decides a retry);
  /// every other outcome — success, delivery error, silent no-op — is true.
  Future<bool> _capture({
    required int? displayId,
    required Rect? rect,
    required CaptureKind kind,
    String? windowTitle,
    String? appName,
    bool silentOnMissingDisplay = false,
  }) async {
    final cap = await _settings.loadCapture();
    // Opt-in decoration is applied NATIVELY inside captureRegion (the captured
    // CGImage is wrapped before encoding), so the delivered bytes are final —
    // no Dart decode/composite/re-encode for the direct modes. The pin leg
    // always shows the undecorated capture (decorationPlan): a pin-only flow
    // skips decoration; alongside other legs native also returns the plain
    // sibling (RegionCapture.plainBytes).
    final plan = decorationPlan(
      decorationEnabled: cap.decorateFor(kind),
      actions: normalizeFlow(cap.flow, forCapture: true),
    );
    final decoration = plan.decorate
        ? logicalDecorationSpec(
            fillArgb: cap.isJpeg ? cap.decorationJpegFill : null,
            shapeFromAlpha: false,
          )
        : null;
    final RegionCapture? result;
    try {
      result = await _captureRegion(
        displayId: displayId,
        rect: rect,
        showsCursor: cap.captureCursor,
        jpeg: cap.isJpeg,
        jpegQuality: cap.jpegQuality,
        decoration: decoration,
        alsoPlain: plan.needsPlainForPin,
      );
    } catch (e) {
      _showError('Capture failed: $e');
      return true; // surfaced -> no retry
    }
    if (result == null) return silentOnMissingDisplay;
    if (cap.shutterSound) _shutter();
    try {
      final flow = await _deliverEncoded(result, cap, kind, windowTitle, appName);
      final ok = (!cap.flow.contains(FlowAction.save) || flow.savedOk) &&
          (!cap.flow.contains(FlowAction.copy) || flow.copiedToClipboard);
      if (ok) {
        if (cap.completionSound) _complete();
      } else {
        _showError('Capture failed');
      }
      _perfMark('directDelivered ok=$ok kind=${kind.name}');
    } catch (e) {
      _showError('Capture failed: $e');
    }
    // Record the captured region for the next "Capture Last Region".
    await _regionStore.save(
        LastRegion(displayId: result.displayId, rect: result.rect));
    return true;
  }
}
