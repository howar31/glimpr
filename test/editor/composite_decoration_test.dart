import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/composite.dart';
import 'package:glimpr/editor/decoration.dart';

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

Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  return (await codec.getNextFrame()).image;
}

const _plain = DecorationStyle(
  margin: 10,
  cornerRadius: 0,
  shadowBlur: 0,
  shadowOffset: ui.Offset.zero,
  shadowColor: ui.Color(0x00000000),
);

void main() {
  test('no decoration: output size unchanged', () async {
    final frozen = await _solid(200, 100, const ui.Color(0xFF00FF00));
    final bytes = await compositeAndCrop(
      frozen: frozen,
      drawables: const [],
      scaleFactor: 1.0,
      logicalSize: const ui.Size(200, 100),
      selectionLogical: null,
    );
    final img = await _decode(bytes);
    expect(img.width, 200);
    expect(img.height, 100);
  });

  test('decoration: PNG enlarged by 2*margin', () async {
    final frozen = await _solid(200, 100, const ui.Color(0xFF00FF00));
    final bytes = await compositeAndCrop(
      frozen: frozen,
      drawables: const [],
      scaleFactor: 1.0,
      logicalSize: const ui.Size(200, 100),
      selectionLogical: null,
      decoration: _plain,
    );
    final img = await _decode(bytes);
    expect(img.width, 220);
    expect(img.height, 120);
  });
}
