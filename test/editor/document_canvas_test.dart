import 'dart:ui' as ui;
import 'package:flutter/widgets.dart' show Offset, Rect, Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/document.dart';
import 'package:glimpr/editor/draw_style.dart';
import 'package:glimpr/editor/drawable.dart';

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

  test('fresh document has no canvas (overlay default)', () {
    const doc = EditorDocument();
    expect(doc.canvasImage, isNull);
    expect(doc.canvasSize, isNull);
    expect(doc.drawables, isEmpty);
  });

  test('drawable edits keep the canvas null (overlay path unchanged)', () {
    final doc = const EditorDocument().add(_rect(0, 0, 10, 10));
    expect(doc.canvasImage, isNull);
    expect(doc.canvasSize, isNull);
    expect(doc.drawables.length, 1);
  });

  test('trimmed sets the canvas image + size and pushes an undo step', () async {
    final img = await _img(40, 30);
    final doc = const EditorDocument()
        .add(_rect(0, 0, 10, 10))
        .trimmed([_rect(0, 0, 5, 5)], img, const Size(40, 30));
    expect(doc.canvasImage, same(img));
    expect(doc.canvasSize, const Size(40, 30));
    expect(doc.drawables.single.bounds, Rect.fromLTRB(0, 0, 5, 5));
    expect(doc.canUndo, isTrue);
  });

  test('undo restores the pre-trim drawables AND canvas (null = original)',
      () async {
    final img = await _img(40, 30);
    final before = const EditorDocument().add(_rect(2, 2, 12, 12));
    final after = before.trimmed([_rect(0, 0, 10, 10)], img, const Size(40, 30));

    final undone = after.undo();
    expect(undone.canvasImage, isNull); // back to host base image
    expect(undone.canvasSize, isNull);
    expect(undone.drawables.single.bounds, Rect.fromLTRB(2, 2, 12, 12));

    final redone = undone.redo();
    expect(redone.canvasImage, same(img));
    expect(redone.canvasSize, const Size(40, 30));
    expect(redone.drawables.single.bounds, Rect.fromLTRB(0, 0, 10, 10));
  });

  test('a drawable edit after a trim inherits the trim canvas', () async {
    final img = await _img(40, 30);
    final trimmed =
        const EditorDocument().trimmed([], img, const Size(40, 30));
    final edited = trimmed.add(_rect(1, 1, 3, 3));
    expect(edited.canvasImage, same(img));
    expect(edited.canvasSize, const Size(40, 30));
    expect(edited.drawables.length, 1);

    // Undo the drawable add keeps the trim canvas; undo the trim drops it.
    final u1 = edited.undo();
    expect(u1.canvasImage, same(img));
    expect(u1.drawables, isEmpty);
    final u2 = u1.undo();
    expect(u2.canvasImage, isNull);
  });

  test('two trims: undo restores the FIRST trim canvas, not null', () async {
    final a = await _img(40, 30);
    final b = await _img(20, 15);
    final doc = const EditorDocument()
        .trimmed([], a, const Size(40, 30))
        .trimmed([], b, const Size(20, 15));
    expect(doc.canvasImage, same(b));
    final undone = doc.undo();
    expect(undone.canvasImage, same(a));
    expect(undone.canvasSize, const Size(40, 30));
  });

  test('moved by -topLeft realigns a drawable to a new crop origin', () {
    final shifted = _rect(20, 30, 40, 50).moved(const Offset(-20, -30));
    expect(shifted.bounds, Rect.fromLTRB(0, 0, 20, 20));
  });
}
