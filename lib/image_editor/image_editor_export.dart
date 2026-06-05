import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui' show Size;
import '../editor/composite.dart';
import '../editor/drawable.dart';
import '../output/deliver.dart';

/// Injectable delivery seam (mirrors deliverCapture's signature) so the orchestration
/// is testable without the real file/clipboard plugins.
typedef DeliverSeam = Future<DeliveryResult> Function({
  required Uint8List pngBytes,
  Directory? saveDir,
  String? fileName,
  bool saveToFile,
  bool copyToClipboard,
});

/// Composite the (full-res) [image] + [drawables] and deliver per the settings —
/// the editor's analog of overlay/export.dart's exportAnnotated (no CapturedDisplay).
/// Whole image (selectionLogical = null); pixelScale 1.0 because [image] is native.
Future<DeliveryResult> exportImage({
  required ui.Image image,
  required List<Drawable> drawables,
  required bool jpeg,
  required int jpegQuality,
  required bool saveToFile,
  required bool copyToClipboard,
  required Directory? saveDir,
  required String sourceName,
  DeliverSeam? deliver,
}) async {
  final bytes = await compositeAndCrop(
    frozen: image,
    drawables: drawables,
    scaleFactor: 1.0,
    logicalSize: Size(image.width.toDouble(), image.height.toDouble()),
    selectionLogical: null,
    jpeg: jpeg,
    jpegQuality: jpegQuality,
  );
  final fn = deliver ??
      ({required pngBytes, saveDir, fileName, saveToFile = true, copyToClipboard = true}) =>
          deliverCapture(
            pngBytes: pngBytes,
            saveDir: saveDir,
            fileName: fileName,
            soundFn: () async {},
            saveToFile: saveToFile,
            copyToClipboard: copyToClipboard,
          );
  return fn(
    pngBytes: bytes,
    saveDir: saveDir,
    fileName: '$sourceName-edited.${jpeg ? 'jpg' : 'png'}',
    saveToFile: saveToFile,
    copyToClipboard: copyToClipboard,
  );
}
