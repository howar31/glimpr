import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/draw_style.dart';
import 'package:glimpr/editor/drawable.dart';
import 'package:glimpr/editor/editor_controller.dart';

void main() {
  test('starts in crop phase with the Crop tool (crop is the default)', () {
    final c = EditorController();
    expect(c.phase.value, EditorPhase.crop);
    expect(c.tool.value, ToolKind.crop);
    c.dispose();
  });

  test('switching to an annotation tool enters the annotate phase', () {
    final c = EditorController();
    c.selectTool(ToolKind.rectangle);
    expect(c.phase.value, EditorPhase.annotate);
    c.dispose();
  });

  test('commitDrawable adds to the document (undoable)', () {
    final c = EditorController();
    c.commitDrawable(
      const RectangleDrawable(Rect.fromLTWH(0, 0, 10, 10), DrawStyle()),
    );
    expect(c.document.value.drawables.length, 1);
    c.undo();
    expect(c.document.value.drawables, isEmpty);
    c.dispose();
  });

  test('setStyle updates the active style for new drawables', () {
    final c = EditorController();
    c.setColor(const Color(0xFF007AFF));
    expect(c.style.value.color, const Color(0xFF007AFF));
    c.dispose();
  });

  test('setColor also restyles the selected drawable (edit)', () {
    final c = EditorController();
    c.commitDrawable(
      const RectangleDrawable(Rect.fromLTWH(0, 0, 10, 10), DrawStyle()),
    );
    c.selectedIndex.value = 0;
    c.setColor(const Color(0xFF34C759));
    final d = c.document.value.drawables[0] as RectangleDrawable;
    expect(d.style.color, const Color(0xFF34C759));
    c.dispose();
  });

  test('enterCrop switches phase to crop', () {
    final c = EditorController();
    c.selectTool(ToolKind.crop);
    expect(c.phase.value, EditorPhase.crop);
    c.dispose();
  });
}
