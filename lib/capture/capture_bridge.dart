import 'package:flutter/services.dart';
import 'captured_display.dart';

/// Dart-side facade over the native `glimpr/capture` MethodChannel.
class CaptureBridge {
  static const _channel = MethodChannel('glimpr/capture');
  static const _overlay = MethodChannel('glimpr/overlay');

  Future<List<CapturedDisplay>> captureAllDisplays() async {
    try {
      final result = await _channel.invokeMethod<List<dynamic>>('captureAllDisplays');
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

  /// Warp the OS mouse cursor to a GLOBAL display point (top-left origin,
  /// logical points) so keyboard nudges move the real pointer, not just the
  /// selection (otherwise the next mouse move resets the nudge).
  Future<void> warpCursor(double x, double y) =>
      _channel.invokeMethod('warpCursor', {'x': x, 'y': y});

  /// Register native -> Dart overlay callbacks. Call once per engine at startup.
  void registerOverlayHandlers({
    required void Function(CapturedDisplay display) onCaptureReady,
    required void Function(String reason, String message) onCaptureFailed,
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
