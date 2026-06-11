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
}
