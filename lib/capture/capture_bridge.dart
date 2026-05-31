import 'package:flutter/services.dart';
import 'captured_display.dart';

/// Dart-side facade over the native `glimpr/capture` MethodChannel.
class CaptureBridge {
  static const _channel = MethodChannel('glimpr/capture');

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
}

class CaptureException implements Exception {
  final String code;
  final String message;
  CaptureException(this.code, this.message);
  @override
  String toString() => 'CaptureException($code): $message';
}
