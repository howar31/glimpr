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

  test('editing a SELECTED drawable does not pollute the active tool default', () {
    final styles = <ToolKind, DrawStyle>{};
    final c = EditorController(toolStyles: styles);
    c.selectTool(ToolKind.rectangle);
    // No selection: setColor sets the rectangle tool's remembered default.
    c.setColor(const Color(0xFFFF0000));
    expect(styles[ToolKind.rectangle]?.color, const Color(0xFFFF0000));
    // Draw + select a rectangle, then edit its colour.
    c.commitDrawable(
      const RectangleDrawable(
        Rect.fromLTWH(0, 0, 10, 10),
        DrawStyle(color: Color(0xFFFF0000)),
      ),
    );
    c.selectedIndex.value = 0;
    c.setColor(const Color(0xFF00FF00));
    // The drawable changed...
    expect(
      (c.document.value.drawables[0] as RectangleDrawable).style.color,
      const Color(0xFF00FF00),
    );
    // ...but the tool default did NOT.
    expect(styles[ToolKind.rectangle]?.color, const Color(0xFFFF0000));
    // Deselecting restores the unpolluted tool default into the option bar.
    c.selectedIndex.value = null;
    expect(c.style.value.color, const Color(0xFFFF0000));
    c.dispose();
  });

  test('resetting a SELECTED drawable does not pollute the active tool default', () {
    final styles = <ToolKind, DrawStyle>{};
    final c = EditorController(toolStyles: styles);
    c.selectTool(ToolKind.rectangle);
    c.setColor(const Color(0xFFFF0000)); // tool default = red
    c.commitDrawable(
      const RectangleDrawable(
        Rect.fromLTWH(0, 0, 10, 10),
        DrawStyle(color: Color(0xFF00FF00)),
      ),
    );
    c.selectedIndex.value = 0;
    c.resetActiveStyle(ToolKind.rectangle); // resets ONLY the selected drawable
    expect(
      (c.document.value.drawables[0] as RectangleDrawable).style.color,
      const DrawStyle().color,
    );
    expect(styles[ToolKind.rectangle]?.color, const Color(0xFFFF0000));
    c.dispose();
  });

  test('enterCrop switches phase to crop', () {
    final c = EditorController();
    c.selectTool(ToolKind.crop);
    expect(c.phase.value, EditorPhase.crop);
    c.dispose();
  });
}
