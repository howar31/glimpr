import 'dart:typed_data';
import 'dart:ui' show Rect;
import 'package:image/image.dart' as img;

/// Crops a single display's native-resolution PNG to a logical, display-local
/// selection rectangle, mapping logical -> pixels via [scaleFactor].
/// Returns PNG bytes, or JPEG bytes when [jpegQuality] (1-100) is provided.
Uint8List cropToSelection({
  required Uint8List pngBytes,
  required double scaleFactor,
  required Rect selection,
  int? jpegQuality,
}) {
  final src = img.decodePng(pngBytes);
  if (src == null) {
    throw ArgumentError('pngBytes is not a decodable PNG');
  }
  var x = (selection.left * scaleFactor).round();
  var y = (selection.top * scaleFactor).round();
  var w = (selection.width * scaleFactor).round();
  var h = (selection.height * scaleFactor).round();
  x = x.clamp(0, src.width);
  y = y.clamp(0, src.height);
  w = w.clamp(1, src.width - x);
  h = h.clamp(1, src.height - y);
  final cropped = img.copyCrop(src, x: x, y: y, width: w, height: h);
  return jpegQuality == null
      ? Uint8List.fromList(img.encodePng(cropped))
      : Uint8List.fromList(img.encodeJpg(cropped, quality: jpegQuality));
}
