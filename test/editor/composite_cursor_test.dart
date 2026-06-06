import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/composite.dart';

Future<ui.Image> _solid(int w, int h, ui.Color c) async {
  final r = ui.PictureRecorder();
  ui.Canvas(r).drawRect(
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = c,
  );
  final p = r.endRecording();
  final img = await p.toImage(w, h);
  p.dispose();
  return img;
}

Future<List<int>> _px(ui.Image img, int x, int y) async {
  final d = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  final b = d!.buffer.asUint8List();
  final i = (y * img.width + x) * 4;
  return [b[i], b[i + 1], b[i + 2], b[i + 3]];
}

void main() {
  test('cursor image is composited at its native top-left', () async {
    final frozen = await _solid(100, 80, const ui.Color(0xFF00FF00));
    final cursor = await _solid(10, 10, const ui.Color(0xFFFF0000));
    final bytes = await compositeAndCrop(
      frozen: frozen,
      drawables: const [],
      scaleFactor: 1.0,
      logicalSize: const ui.Size(100, 80),
      selectionLogical: null,
      cursorImage: cursor,
      cursorTopLeftNative: const ui.Offset(50, 40),
    );
    final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
    final out = (await codec.getNextFrame()).image;
    expect(await _px(out, 55, 45), [255, 0, 0, 255]); // inside the cursor
    expect(await _px(out, 10, 10), [0, 255, 0, 255]); // base, untouched
  });

  test('no cursor -> base unchanged', () async {
    final frozen = await _solid(100, 80, const ui.Color(0xFF00FF00));
    final bytes = await compositeAndCrop(
      frozen: frozen,
      drawables: const [],
      scaleFactor: 1.0,
      logicalSize: const ui.Size(100, 80),
      selectionLogical: null,
    );
    final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
    final out = (await codec.getNextFrame()).image;
    expect(await _px(out, 55, 45), [0, 255, 0, 255]);
  });
}
