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

  test('setHighlighterTexture updates style and remembers it per tool', () {
    final c = EditorController();
    c.selectTool(ToolKind.highlighter);
    c.setHighlighterTexture(HighlighterTexture.frayed);
    expect(c.style.value.texture, HighlighterTexture.frayed);
    expect(c.toolStyles[ToolKind.highlighter]!.texture, HighlighterTexture.frayed);
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

  test('setFillColor sets a fill and canonicalizes a transparent pick to none', () {
    final c = EditorController();
    c.selectTool(ToolKind.rectangle);
    c.setFillColor(const Color(0x804CD964));
    expect(c.style.value.fillColor, const Color(0x804CD964));
    // Any fully transparent pick collapses to the exact no-fill default so the
    // reset button (style != default) reads correctly and JSON omits it.
    c.setFillColor(const Color(0x00FF0000));
    expect(c.style.value.fillColor, const Color(0x00000000));
  });

  test('setCornerRadius clamps to [0, kCornerRadiusMax]', () {
    final c = EditorController();
    c.selectTool(ToolKind.rectangle);
    c.setCornerRadius(16);
    expect(c.style.value.cornerRadius, 16);
    c.setCornerRadius(999);
    expect(c.style.value.cornerRadius, kCornerRadiusMax);
    c.setCornerRadius(-5);
    expect(c.style.value.cornerRadius, 0);
  });

  test('setCornerRadiusAuto reverts to the auto sentinel, leaving other fields', () {
    final c = EditorController();
    c.selectTool(ToolKind.rectangle);
    c.setStrokeWidth(20);
    c.setCornerRadius(24);
    expect(c.style.value.cornerRadius, 24);
    c.setCornerRadiusAuto();
    expect(c.style.value.cornerRadius, kCornerRadiusAuto);
    expect(c.style.value.strokeWidth, 20); // unrelated fields untouched
  });

  test('setOutlineColor sets an outline and canonicalizes a transparent pick', () {
    final c = EditorController();
    c.selectTool(ToolKind.text);
    c.setOutlineColor(const Color(0xFFFFFFFF));
    expect(c.style.value.outlineColor, const Color(0xFFFFFFFF));
    c.setOutlineColor(const Color(0x00123456));
    expect(c.style.value.outlineColor, const Color(0x00000000));
  });
}
