import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/draw_style.dart';
import 'package:glimpr/editor/drawable.dart';
import 'package:glimpr/editor/document.dart';

void main() {
  const style = DrawStyle();
  RectangleDrawable rect(double x) =>
      RectangleDrawable(Rect.fromLTWH(x, 0, 10, 10), style);

  test('add pushes onto the list and clears redo', () {
    var doc = const EditorDocument();
    doc = doc.add(rect(0)).add(rect(1));
    expect(doc.drawables.length, 2);
    expect(doc.canUndo, isTrue);
    expect(doc.canRedo, isFalse);
  });

  test('undo/redo walks history', () {
    var doc = const EditorDocument().add(rect(0)).add(rect(1));
    doc = doc.undo();
    expect(doc.drawables.length, 1);
    expect(doc.canRedo, isTrue);
    doc = doc.redo();
    expect(doc.drawables.length, 2);
  });

  test('a new edit after undo clears the redo branch', () {
    var doc = const EditorDocument().add(rect(0)).add(rect(1)).undo();
    doc = doc.add(rect(2));
    expect(doc.drawables.length, 2);
    expect(doc.drawables.last, isA<RectangleDrawable>());
    expect(doc.canRedo, isFalse);
  });

  test('replaceAt and removeAt are undoable', () {
    var doc = const EditorDocument().add(rect(0));
    doc = doc.replaceAt(0, rect(5));
    expect((doc.drawables[0] as RectangleDrawable).rect.left, 5);
    doc = doc.undo();
    expect((doc.drawables[0] as RectangleDrawable).rect.left, 0);
    doc = doc.removeAt(0);
    expect(doc.drawables, isEmpty);
  });

  test('replaceAtSilent edits in place without adding an undo step', () {
    var doc = const EditorDocument().add(rect(0)).add(rect(1));
    doc = doc.replaceAtSilent(1, rect(9)); // e.g. a pixelate mosaic backfill
    expect((doc.drawables[1] as RectangleDrawable).rect.left, 9);
    // One undo goes straight back to the single-drawable state -> the silent
    // replace added no history entry of its own.
    doc = doc.undo();
    expect(doc.drawables.length, 1);
    expect((doc.drawables[0] as RectangleDrawable).rect.left, 0);
  });

  test('replaceAtSilent out of range is a no-op', () {
    final doc = const EditorDocument().add(rect(0));
    expect(doc.replaceAtSilent(5, rect(9)).drawables.length, 1);
  });
}
