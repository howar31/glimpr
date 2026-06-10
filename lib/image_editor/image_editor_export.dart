import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui' show Size;
import '../editor/composite.dart';
import '../editor/drawable.dart';
import '../output/flow.dart';

/// Injectable flow seam (mirrors runFlow's core inputs) so the orchestration is
/// testable without the real file/clipboard plugins.
typedef RunFlowSeam = Future<FlowResult> Function({
  required Set<FlowAction> actions,
  required Uint8List bytes,
  Directory? saveDir,
  String? fileName,
});

/// Composite the (full-res) [image] + [drawables] and run [actions] (the
/// editor-Done flow or a one-off) — the editor's analog of overlay/export.dart's
/// exportAnnotated (no CapturedDisplay). Whole image (selectionLogical = null);
/// pixelScale 1.0 because [image] is native.
Future<FlowResult> exportImage({
  required ui.Image image,
  required List<Drawable> drawables,
  required bool jpeg,
  required int jpegQuality,
  required Set<FlowAction> actions,
  required Directory? saveDir,
  required String sourceName,
  RunFlowSeam? run,
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
  final fn = run ??
      ({required actions, required bytes, saveDir, fileName}) => runFlow(
            actions: actions,
            bytes: bytes,
            saveDir: saveDir,
            fileName: fileName,
            soundFn: () async {},
          );
  return fn(
    actions: actions,
    bytes: bytes,
    saveDir: saveDir,
    fileName: '$sourceName-edited.${jpeg ? 'jpg' : 'png'}',
  );
}
