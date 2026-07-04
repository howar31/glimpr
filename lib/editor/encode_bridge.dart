import 'package:flutter/services.dart';

import '../channels.dart';

/// Native JPEG encoder bridge. The `glimpr/encode` channel is registered on
/// EVERY engine (control / overlay / image editor), so the editor layer can
/// call it host-agnostically. Returns null when the channel is unavailable
/// (unit tests, hosts without the handler) or encoding fails — the caller
/// falls back to the pure-Dart encoder.
Future<Uint8List?> encodeJpegNative(
    Uint8List rgba, int width, int height, int quality) async {
  try {
    final res = await kEncodeChannel.invokeMethod('jpeg', {
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

/// Native PNG encoder (ImageIO): raw RGBA8888 in, PNG bytes out, alpha
/// preserved. Returns null when the channel is unavailable or encoding fails
/// — the caller falls back to dart:ui's toByteData(png).
Future<Uint8List?> encodePngNative(
    Uint8List rgba, int width, int height) async {
  try {
    final res = await kEncodeChannel.invokeMethod('png', {
      'rgba': rgba,
      'width': width,
      'height': height,
    });
    return res as Uint8List?;
  } catch (_) {
    return null;
  }
}
