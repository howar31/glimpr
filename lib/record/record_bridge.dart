import 'package:flutter/services.dart';

/// Dart-side facade over the native `glimpr/record` MethodChannel — the
/// screen-recording seam (control engine only). All recording pixel/encode
/// work is native (SCStream + SCRecordingOutput, macOS 15+); Dart sends
/// control calls and receives lifecycle events.
class RecordBridge {
  static const _channel = MethodChannel('glimpr/record');

  /// Whether the native recording module exists (macOS 15+). False also when
  /// the channel is missing (tests, other hosts).
  Future<bool> isAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Start a recording. [mode]: region | window | display | lastRegion.
  /// Region mode runs the native live selector first; [rect] is display-local
  /// top-left logical points (lastRegion mode), [windowId] the CGWindowID
  /// (window mode). The result arrives via the onRecord* events.
  Future<void> start({
    required String mode,
    required String outputPath,
    int? displayId,
    Rect? rect,
    int? windowId,
    int fps = 30,
    bool hevc = false,
    bool gif = false,
    bool showsCursor = true,
    bool systemAudio = false,
    bool microphone = false,
    int maxDuration = 0,
    int countdown = 0,
  }) =>
      _channel.invokeMethod('start', {
        'mode': mode,
        'outputPath': outputPath,
        'displayId': ?displayId,
        if (rect != null) ...{
          'x': rect.left, 'y': rect.top, 'w': rect.width, 'h': rect.height,
        },
        'windowId': ?windowId,
        'fps': fps,
        'hevc': hevc,
        'gif': gif,
        'showsCursor': showsCursor,
        'systemAudio': systemAudio,
        'microphone': microphone,
        'maxDuration': maxDuration,
        'countdown': countdown,
      });

  /// Stop the active recording (file finalizes -> onRecordFinished).
  Future<void> stop() => _channel.invokeMethod('stop');

  /// Abort the active recording (file deleted -> onRecordAborted).
  Future<void> abort() => _channel.invokeMethod('abort');

  /// Pause the active recording (the timeline freezes; one continuous file).
  Future<void> pause() => _channel.invokeMethod('pause');

  /// Resume a paused recording.
  Future<void> resume() => _channel.invokeMethod('resume');

  /// Register native -> Dart recording lifecycle events. Call once in the
  /// control engine. [onSelection] delivers a live-select confirm/cancel
  /// relayed from an overlay engine (displayId + rect | windowId, or
  /// cancelled: true).
  void registerHandlers({
    required void Function(int displayId, Rect rect) onStarted,
    required void Function(String path) onFinished,
    required void Function(String message) onFailed,
    required void Function() onAborted,
    void Function(Map<String, dynamic> args)? onSelection,
    void Function()? onPaused,
    void Function()? onResumed,
  }) {
    _channel.setMethodCallHandler((call) async {
      final args = call.arguments;
      switch (call.method) {
        case 'onRecordSelection':
          onSelection?.call((args as Map).cast<String, dynamic>());
        case 'onRecordPaused':
          onPaused?.call();
        case 'onRecordResumed':
          onResumed?.call();
        case 'onRecordStarted':
          final a = (args as Map).cast<String, dynamic>();
          onStarted(
            (a['displayId'] as num?)?.toInt() ?? 0,
            Rect.fromLTWH(
              (a['x'] as num?)?.toDouble() ?? 0,
              (a['y'] as num?)?.toDouble() ?? 0,
              (a['w'] as num?)?.toDouble() ?? 0,
              (a['h'] as num?)?.toDouble() ?? 0,
            ),
          );
        case 'onRecordFinished':
          onFinished(((args as Map)['path'] as String?) ?? '');
        case 'onRecordFailed':
          onFailed(((args as Map)['message'] as String?) ?? 'unknown');
        case 'onRecordAborted':
          onAborted();
      }
      return null;
    });
  }
}
