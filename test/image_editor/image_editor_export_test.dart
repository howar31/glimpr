import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/image_editor/image_editor_export.dart';
import 'package:glimpr/output/deliver.dart';
import 'package:glimpr/output/flow.dart';

Future<ui.Image> _img(int w, int h) {
  final r = ui.PictureRecorder();
  ui.Canvas(r);
  return r.endRecording().toImage(w, h);
}

void main() {
  test('exportImage composites then runs the flow via the seam', () async {
    final image = await _img(20, 10);
    Uint8List? delivered;
    Set<FlowAction>? ran;
    final result = await exportImage(
      image: image,
      drawables: const [],
      jpeg: false,
      jpegQuality: 90,
      actions: {FlowAction.save},
      saveDir: null,
      fileName: 'photo_2026-06-15.png',
      run: ({required actions, required bytes, saveDir, fileName}) async {
        delivered = bytes;
        ran = actions;
        expect(fileName, 'photo_2026-06-15.png');
        return const FlowResult(DeliveryResult(
            copiedToClipboard: false,
            soundPlayed: false,
            savedPath: '/tmp/x.png'));
      },
    );
    expect(delivered, isNotNull);
    expect(delivered!.isNotEmpty, isTrue); // real PNG bytes from compositeAndCrop
    expect(ran, {FlowAction.save});
    expect(result.savedOk, isTrue);
  });
}
