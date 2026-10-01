import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/editor_controller.dart';

void main() {
  group('eyedropper vs tool switches', () {
    test('default: a tool switch cancels sampling and switches', () {
      final c = EditorController(toolStyles: {});
      c.eyedropperActive.value = true;
      c.selectTool(ToolKind.rectangle);
      expect(c.eyedropperActive.value, isFalse);
      expect(c.tool.value, ToolKind.rectangle);
      c.dispose();
    });

    test('modal mode: tool switches are ignored while sampling', () {
      final c = EditorController(toolStyles: {});
      c.eyedropperToolSwitchCancels = false;
      final before = c.tool.value;
      c.eyedropperActive.value = true;
      c.selectTool(ToolKind.rectangle);
      expect(c.eyedropperActive.value, isTrue);
      expect(c.tool.value, before);
      // Sampling over -> switching works again.
      c.eyedropperActive.value = false;
      c.selectTool(ToolKind.rectangle);
      expect(c.tool.value, ToolKind.rectangle);
      c.dispose();
    });

    test('not sampling: selectTool never touches the eyedropper flag', () {
      final c = EditorController(toolStyles: {});
      c.selectTool(ToolKind.pen);
      expect(c.eyedropperActive.value, isFalse);
      expect(c.tool.value, ToolKind.pen);
      c.dispose();
    });
  });

  group('eyedropper sample target', () {
    const sampled = Color(0xFF336699);

    test('stroke: writes the stroke colour and keeps its alpha', () {
      final c = EditorController(toolStyles: {});
      c.setColor(const Color(0x80FF0000));
      c.startEyedropper();
      c.applySampledColor(sampled);
      expect(c.style.value.color, sampled.withValues(alpha: 0x80 / 255));
      c.dispose();
    });

    test('fill: writes the fill colour only and keeps its alpha', () {
      final c = EditorController(toolStyles: {});
      final stroke = c.style.value.color;
      c.setFillColor(const Color(0x80FF0000));
      c.startEyedropper(EyedropperTarget.fill);
      expect(c.eyedropperActive.value, isTrue);
      c.applySampledColor(sampled);
      expect(c.style.value.fillColor, sampled.withValues(alpha: 0x80 / 255));
      expect(c.style.value.color, stroke);
      c.dispose();
    });

    test('fill / outline at alpha 0 (none) become opaque on a sample', () {
      final c = EditorController(toolStyles: {});
      c.setFillColor(const Color(0x00000000));
      c.setOutlineColor(const Color(0x00000000));
      c.startEyedropper(EyedropperTarget.fill);
      c.applySampledColor(sampled);
      expect(c.style.value.fillColor, sampled);
      c.startEyedropper(EyedropperTarget.outline);
      c.applySampledColor(sampled);
      expect(c.style.value.outlineColor, sampled);
      c.dispose();
    });
  });
}
