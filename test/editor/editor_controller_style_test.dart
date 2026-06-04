import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/draw_style.dart';
import 'package:glimpr/editor/editor_controller.dart';

void main() {
  test('setFontFamily updates style and remembers it per tool', () {
    final c = EditorController();
    c.selectTool(ToolKind.text);
    c.setFontFamily('PingFang TC');
    expect(c.style.value.fontFamily, 'PingFang TC');
    expect(c.toolStyles[ToolKind.text]!.fontFamily, 'PingFang TC');
  });

  test('resetTool restores the default style for that tool', () {
    final c = EditorController();
    c.selectTool(ToolKind.rectangle);
    c.setStrokeWidth(20);
    c.setColor(const Color(0xFF00FF00));
    expect(c.toolStyles[ToolKind.rectangle], isNot(const DrawStyle()));
    c.resetTool(ToolKind.rectangle);
    expect(c.style.value, const DrawStyle());
    expect(c.toolStyles[ToolKind.rectangle], const DrawStyle());
  });

  test('resetTool on a non-active tool clears its memory', () {
    final c = EditorController();
    c.selectTool(ToolKind.arrow);
    c.setStrokeWidth(16);
    c.selectTool(ToolKind.text); // switch away
    c.resetTool(ToolKind.arrow);
    expect(c.toolStyles[ToolKind.arrow], const DrawStyle());
  });
}
