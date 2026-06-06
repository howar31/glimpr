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

// A mask: left half opaque, right half transparent.
Future<ui.Image> _halfMask(int w, int h) async {
  final r = ui.PictureRecorder();
  ui.Canvas(r).drawRect(
    ui.Rect.fromLTWH(0, 0, w / 2, h.toDouble()),
    ui.Paint()..color = const ui.Color(0xFF000000),
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
  test('windowMask keeps masked-in pixels, drops masked-out to transparent',
      () async {
    final frozen = await _solid(100, 80, const ui.Color(0xFF00FF00));
    final mask = await _halfMask(100, 80);
    final bytes = await compositeAndCrop(
      frozen: frozen,
      drawables: const [],
      scaleFactor: 1.0,
      logicalSize: const ui.Size(100, 80),
      selectionLogical: null,
      windowMask: mask,
    );
    final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
    final out = (await codec.getNextFrame()).image;
    expect((await _px(out, 10, 40))[3], 255); // left half kept opaque
    expect((await _px(out, 90, 40))[3], 0); // right half masked out
  });
}
