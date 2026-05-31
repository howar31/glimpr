import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/draw_style.dart';
import 'package:glimpr/editor/drawable.dart';
import 'package:glimpr/editor/editor_controller.dart';

void main() {
  test('starts in annotate phase with Select tool', () {
    final c = EditorController();
    expect(c.phase.value, EditorPhase.annotate);
    expect(c.tool.value, ToolKind.select);
    c.dispose();
  });

  test('commitDrawable adds to the document (undoable)', () {
    final c = EditorController();
    c.commitDrawable(
        const RectangleDrawable(Rect.fromLTWH(0, 0, 10, 10), DrawStyle()));
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

  test('enterCrop switches phase to crop', () {
    final c = EditorController();
    c.selectTool(ToolKind.crop);
    expect(c.phase.value, EditorPhase.crop);
    c.dispose();
  });
}
