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

  List<double> lefts(EditorDocument d) =>
      d.drawables.map((x) => (x as RectangleDrawable).rect.left).toList();

  test('insertAt places a drawable at the index and grows the list', () {
    var doc = const EditorDocument().add(rect(0)).add(rect(2));
    doc = doc.insertAt(1, rect(1));
    expect(doc.drawables.length, 3);
    expect(lefts(doc), [0, 1, 2]);
    expect(doc.canUndo, isTrue);
  });

  test('moveToFront moves the item to the end (top)', () {
    var doc = const EditorDocument().add(rect(0)).add(rect(1)).add(rect(2));
    doc = doc.moveToFront(0);
    expect(lefts(doc), [1, 2, 0]);
  });

  test('moveToBack moves the item to index 0 (bottom)', () {
    var doc = const EditorDocument().add(rect(0)).add(rect(1)).add(rect(2));
    doc = doc.moveToBack(2);
    expect(lefts(doc), [2, 0, 1]);
  });

  test('moveToFront/moveToBack are no-ops (no undo step) at the edge or out of range', () {
    final base = const EditorDocument().add(rect(0)).add(rect(1));
    expect(identical(base.moveToFront(1), base), isTrue); // already last
    expect(identical(base.moveToBack(0), base), isTrue); // already first
    expect(identical(base.moveToFront(9), base), isTrue); // out of range
    expect(identical(base.moveToBack(9), base), isTrue); // out of range
  });

  test('undo reverses a reorder', () {
    var doc = const EditorDocument().add(rect(0)).add(rect(1));
    doc = doc.moveToBack(1);
    expect(lefts(doc), [1, 0]);
    doc = doc.undo();
    expect(lefts(doc), [0, 1]);
  });

  test('withDrawables replaces the list as ONE undo step', () {
    var doc = const EditorDocument().add(rect(0));
    doc = doc.withDrawables([
      const SpotlightDrawable(Rect.fromLTWH(0, 0, 2, 2), style),
      const SpotlightDrawable(Rect.fromLTWH(5, 5, 2, 2), style),
    ]);
    expect(doc.drawables.length, 2);
    final undone = doc.undo();
    expect(undone.drawables.length, 1);
    expect(undone.drawables.single, isA<RectangleDrawable>());
  });
}
