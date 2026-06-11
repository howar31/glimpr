import 'package:flutter/services.dart';

/// Native CG decoration + encode bridge over `glimpr/encode` (registered on
/// EVERY engine). Wraps the composited content (raw RGBA8888, premultiplied) in
/// the decoration [spec] (margin + rounded corners / alpha-shape + drop shadow
/// + optional fill), scaling the spec's lengths by [scale], and encodes ONCE
/// (ImageIO, PNG or JPEG per [jpeg]). Returns null when the channel is
/// unavailable (unit tests, hosts without the handler) or rendering fails — the
/// caller falls back to the dart:ui decoration path. Same model as
/// `encodeJpegNative` (encode_bridge.dart).
Future<Uint8List?> decorateNative({
  required Uint8List rgba,
  required int width,
  required int height,
  required double scale,
  required Map<String, dynamic> spec,
  required bool jpeg,
  required int quality,
}) async {
  try {
    final res =
        await const MethodChannel('glimpr/encode').invokeMethod('decorate', {
      'rgba': rgba,
      'width': width,
      'height': height,
      'scale': scale,
      'decoration': spec,
      'jpeg': jpeg,
      'quality': quality,
    });
    return res as Uint8List?;
  } catch (_) {
    return null; // MissingPluginException, PlatformException -> Dart fallback
  }
}
