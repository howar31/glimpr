import 'package:flutter/services.dart';

/// Native JPEG encoder bridge. The `glimpr/encode` channel is registered on
/// EVERY engine (control / overlay / image editor), so the editor layer can
/// call it host-agnostically. Returns null when the channel is unavailable
/// (unit tests, hosts without the handler) or encoding fails — the caller
/// falls back to the pure-Dart encoder.
Future<Uint8List?> encodeJpegNative(
    Uint8List rgba, int width, int height, int quality) async {
  try {
    final res =
        await const MethodChannel('glimpr/encode').invokeMethod('jpeg', {
      'rgba': rgba,
      'width': width,
      'height': height,
      'quality': quality,
    });
    return res as Uint8List?;
  } catch (_) {
    return null; // MissingPluginException, PlatformException -> Dart fallback
  }
}
