import 'package:flutter/services.dart';
import 'captured_display.dart';

/// Dart-side facade over the native `glimpr/capture` MethodChannel.
class CaptureBridge {
  static const _channel = MethodChannel('glimpr/capture');
  static const _overlay = MethodChannel('glimpr/overlay');

  Future<List<CapturedDisplay>> captureAllDisplays() async {
    try {
      final result = await _channel.invokeMethod<List<dynamic>>(
        'captureAllDisplays',
      );
      if (result == null) return const [];
      return result
          .cast<Map<dynamic, dynamic>>()
          .map(CapturedDisplay.fromMap)
          .toList(growable: false);
    } on PlatformException catch (e) {
      throw CaptureException(e.code, e.message ?? '');
    }
  }

  /// Trigger the overlay capture flow (native captures + pushes + shows).
  Future<void> beginCapture() => _channel.invokeMethod('beginCapture');

  /// Hide all overlay windows and release buffers (Esc-cancel or capture-fire).
  Future<void> dismissOverlay() => _channel.invokeMethod('dismissOverlay');

  /// Signal that this overlay engine has rasterized its first frame, so native
  /// may order its window front (capture-then-show).
  Future<void> overlayReady() => _channel.invokeMethod('overlayReady');

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
        default:
          return null; // onWindowsRefreshed etc. are Phase 4 — ignore.
      }
    });
  }
}

class CaptureException implements Exception {
  final String code;
  final String message;
  CaptureException(this.code, this.message);
  @override
  String toString() => 'CaptureException($code): $message';
}
