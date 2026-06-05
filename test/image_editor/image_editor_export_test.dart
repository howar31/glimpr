import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/image_editor/image_editor_export.dart';
import 'package:glimpr/output/deliver.dart';

Future<ui.Image> _img(int w, int h) {
  final r = ui.PictureRecorder();
  ui.Canvas(r);
  return r.endRecording().toImage(w, h);
}

void main() {
  test('exportImage composites then delivers PNG bytes via the seam', () async {
    final image = await _img(20, 10);
    Uint8List? delivered;
    final result = await exportImage(
      image: image,
      drawables: const [],
      jpeg: false,
      jpegQuality: 90,
      saveToFile: true,
      copyToClipboard: false,
      saveDir: null,
      sourceName: 'photo',
      deliver: ({required pngBytes, saveDir, fileName, saveToFile = true, copyToClipboard = true}) async {
        delivered = pngBytes;
        return const DeliveryResult(copiedToClipboard: false, soundPlayed: false, savedPath: '/tmp/x.png');
      },
    );
    expect(delivered, isNotNull);
    expect(delivered!.isNotEmpty, isTrue); // real PNG bytes from compositeAndCrop
    expect(result.savedOk, isTrue);
  });
}
