import 'dart:ui' as ui;
import 'package:flutter/widgets.dart' show Rect, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/draw_style.dart';
import 'package:glimpr/editor/drawable.dart';
import 'package:glimpr/editor/editor_controller.dart';

Future<ui.Image> _img(int w, int h) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );
  final pic = recorder.endRecording();
  final img = await pic.toImage(w, h);
  pic.dispose();
  return img;
}

RectangleDrawable _rect(double l, double t, double r, double b) =>
    RectangleDrawable(Rect.fromLTRB(l, t, r, b), const DrawStyle());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('commitTrim pushes the trimmed canvas; undo restores drawables + canvas',
      () async {
    final img = await _img(20, 10);
    final c = EditorController();
    c.commitDrawable(_rect(5, 5, 15, 15));
    // Caller (EditorCore) shifts drawables by -rect.topLeft before committing.
    c.commitTrim([_rect(0, 0, 10, 10)], img, const Size(20, 10));

    expect(c.document.value.canvasImage, same(img));
    expect(c.document.value.canvasSize, const Size(20, 10));
    expect(c.document.value.drawables.single.bounds, Rect.fromLTRB(0, 0, 10, 10));
    expect(c.document.value.canUndo, isTrue);

    c.undo();
    expect(c.document.value.canvasImage, isNull); // back to the host base image
    expect(c.document.value.canvasSize, isNull);
    expect(c.document.value.drawables.single.bounds, Rect.fromLTRB(5, 5, 15, 15));

    c.redo();
    expect(c.document.value.canvasImage, same(img));
    expect(c.document.value.drawables.single.bounds, Rect.fromLTRB(0, 0, 10, 10));
    c.dispose();
  });
}
