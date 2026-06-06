import 'package:flutter/services.dart';
import 'captured_display.dart';

/// Dart-side facade over the native `glimpr/capture` MethodChannel.
class CaptureBridge {
  static const _channel = MethodChannel('glimpr/capture');
  static const _overlay = MethodChannel('glimpr/overlay');

  /// Trigger the overlay capture flow (native captures + pushes + shows).
  Future<void> beginCapture() => _channel.invokeMethod('beginCapture');

  /// Capture every display and RETURN the frames to this (control) engine,
  /// WITHOUT showing the overlay — for the direct (non-interactive) modes.
  Future<List<CapturedDisplay>> captureFrames({bool showsCursor = false}) async {
    final res = await _channel.invokeMethod(
      'captureFrames',
      {'showsCursor': showsCursor},
    );
    final list = (res as List).cast<dynamic>();
    return list
        .map((e) => CapturedDisplay.fromMap((e as Map).cast<dynamic, dynamic>()))
        .toList(growable: false);
  }

  /// The frontmost focused window's display-local rect + names, or null if none.
  Future<FocusedWindowInfo?> focusedWindow() async {
    final res = await _channel.invokeMethod('focusedWindow');
    if (res == null) return null;
    return FocusedWindowInfo.fromMap((res as Map).cast<dynamic, dynamic>());
  }

  /// Capture a single window with real alpha (rounded corners), or null when no
  /// such window / the native capture failed -> callers fall back to a rect crop.
  Future<WindowImage?> captureWindowImage(
    int windowId, {
    bool showsCursor = false,
  }) async {
    final res = await _channel.invokeMethod(
      'captureWindowImage',
      {'windowId': windowId, 'showsCursor': showsCursor},
    );
    if (res == null) return null;
    return WindowImage.fromMap((res as Map).cast<dynamic, dynamic>());
  }

  /// Hide all overlay windows and release buffers (Esc-cancel or capture-fire).
  Future<void> dismissOverlay() => _channel.invokeMethod('dismissOverlay');

  /// Reveal the Settings window (⌘, from the capture overlay). The caller
  /// dismisses the overlay first, since it sits above normal windows.
  Future<void> openSettings() => _channel.invokeMethod('openSettings');

  /// Show a native error alert — used when a BACKGROUND export fails after the
  /// overlay was already hidden (so the in-overlay toast is no longer available).
  Future<void> showError(String message) =>
      _channel.invokeMethod('showError', {'message': message});

  /// Signal that this overlay engine has rasterized its first frame, so native
  /// may order its window front (capture-then-show).
  Future<void> overlayReady() => _channel.invokeMethod('overlayReady');

  /// Hide / show the system cursor (the active editor engine drives this — hidden
  /// over the canvas where we draw our own crosshair/reticle, shown over the
  /// toolbar). Native keeps it balanced and always restores it on dismiss.
  Future<void> setCursorHidden(bool hidden) =>
      _channel.invokeMethod('setCursorHidden', {'hidden': hidden});

  /// Confine the cursor to this display while a draw/crop drag runs (and freeze
  /// the cross-display active handoff), so a stroke can't be broken by the cursor
  /// wandering onto another display. Released when the drag ends.
  Future<void> setDrawingLock(bool locked) =>
      _channel.invokeMethod('setDrawingLock', {'locked': locked});

  /// Broadcast the active tool + style to the OTHER displays' editors so the
  /// tool/colour/width/font stay in sync across displays.
  Future<void> broadcastEditorState(Map<String, dynamic> state) =>
      _channel.invokeMethod('broadcastEditorState', state);

  /// Warp the OS mouse cursor to a GLOBAL display point (top-left origin,
  /// logical points) so keyboard nudges move the real pointer, not just the
  /// selection (otherwise the next mouse move resets the nudge).
  Future<void> warpCursor(double x, double y) =>
      _channel.invokeMethod('warpCursor', {'x': x, 'y': y});

  /// Register native -> Dart overlay callbacks. Call once per engine at startup.
  void registerOverlayHandlers({
    required void Function(CapturedDisplay display) onCaptureReady,
    required void Function(String reason, String message) onCaptureFailed,
    void Function(int activeId, Offset cursor)? onActiveDisplay,
    void Function(Map<String, dynamic> state)? onEditorState,
    void Function()? onSettingsOpen,
    void Function()? onResume,
  }) {
    _overlay.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onCaptureReady':
          final args = (call.arguments as Map);
          final map = (args['display'] as Map).cast<dynamic, dynamic>();
          onCaptureReady(CapturedDisplay.fromMap(map));
          return null;
        case 'onCaptureFailed':
          final args = (call.arguments as Map);
          onCaptureFailed(
            args['reason'] as String,
            (args['message'] as String?) ?? '',
          );
          return null;
        case 'onActiveDisplay':
          // The cursor poll picked the active display for ALL engines. This one
          // shows its HUD only when activeId == its own display id.
          final a = (call.arguments as Map);
          onActiveDisplay?.call(
            a['activeId'] as int,
            Offset(
              (a['cursorX'] as num).toDouble(),
              (a['cursorY'] as num).toDouble(),
            ),
          );
          return null;
        case 'onEditorState':
          // Another display changed tool/style -> mirror it here.
          onEditorState?.call((call.arguments as Map).cast<String, dynamic>());
          return null;
        case 'onSettingsOpen':
          // ⌘, paused this freeze for Settings -> show the dim mask.
          onSettingsOpen?.call();
          return null;
        case 'onResume':
          // The freeze was resumed after a ⌘, Settings detour -> drop the mask +
          // re-read settings.
          onResume?.call();
          return null;
        default:
          return null; // onWindowsRefreshed etc. are Phase 4 — ignore.
      }
    });
  }
}
