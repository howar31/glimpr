import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:glimpr/capture/captured_display.dart';
import 'package:glimpr/overlay/export.dart';

void main() {
  CapturedDisplay displayWith(Uint8List png) => CapturedDisplay(
        displayId: 1, pngBytes: png, left: 0, top: 0, width: 100, height: 50,
        scaleFactor: 2.0, isCursorDisplay: true,
      );

  Uint8List solid() {
    final im = img.Image(width: 200, height: 100); // native = logical(100x50) * 2.0
    img.fill(im, color: img.ColorRgba8(0, 128, 255, 255));
    return Uint8List.fromList(img.encodePng(im));
  }

  test('crops display-local selection to native pixels and saves', () async {
    final tmp = await Directory.systemTemp.createTemp('glimpr_export_');
    final d = displayWith(solid());
    // Select logical 0,0 50x25 -> native 0,0 100x50.
    final path = await exportSelection(
      display: d, selection: const Rect.fromLTWH(0, 0, 50, 25), saveDir: tmp,
    );
    final decoded = img.decodePng(await File(path).readAsBytes())!;
    expect(decoded.width, 100);
    expect(decoded.height, 50);
    await tmp.delete(recursive: true);
  });
}
