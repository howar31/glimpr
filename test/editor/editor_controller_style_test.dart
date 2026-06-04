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

  test(
    'highlighter default is translucent (distinct from the uniform default)',
    () {
      final def = defaultStyleFor(ToolKind.highlighter);
      expect(def.color.a, lessThan(1.0)); // translucent
      expect(def, isNot(const DrawStyle())); // not the uniform default
      expect(defaultStyleFor(ToolKind.rectangle), const DrawStyle());
    },
  );

  test(
    'selecting the highlighter (no saved style) seeds its translucent default',
    () {
      final c = EditorController();
      c.selectTool(ToolKind.rectangle);
      c.setColor(const Color(0xFFFF0000)); // opaque red on rectangle
      c.selectTool(ToolKind.highlighter); // must NOT carry over the opaque red
      expect(c.style.value, defaultStyleFor(ToolKind.highlighter));
      expect(c.style.value.color.a, lessThan(1.0));
    },
  );

  test('resetTool restores the highlighter translucent default', () {
    final c = EditorController();
    c.selectTool(ToolKind.highlighter);
    c.setColor(const Color(0xFF00FF00)); // opaque
    c.resetTool(ToolKind.highlighter);
    expect(c.style.value, defaultStyleFor(ToolKind.highlighter));
  });
}
