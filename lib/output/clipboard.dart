import 'package:flutter/services.dart';

/// Self-owned image clipboard over the per-engine `glimpr/clipboard` channel
/// (registered on every engine) — replaces the `pasteboard` package.
///
/// [clipboardWriteImage] sends the already-encoded image bytes: PNG is put on
/// the pasteboard directly (no NSImage/TIFF detour); other encodings (JPEG) are
/// decoded once to PNG natively. [clipboardReadImage] returns the clipboard
/// image as PNG bytes, or null when the clipboard holds no image.
const MethodChannel _clipboard = MethodChannel('glimpr/clipboard');

/// Write [bytes] (an encoded image, PNG or JPEG) to the system clipboard.
/// Throws (PlatformException) when the native write fails, so a delivery leg can
/// record the failure.
Future<void> clipboardWriteImage(Uint8List bytes) async {
  await _clipboard.invokeMethod('writeImage', {'bytes': bytes});
}

/// The clipboard's image as PNG bytes, or null when it holds no image.
Future<Uint8List?> clipboardReadImage() async {
  final res = await _clipboard.invokeMethod('readImage');
  return res as Uint8List?;
}
