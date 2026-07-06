import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/editor_controller.dart';
import 'package:glimpr/editor/tool_style_store.dart';

import '../support/fake_store.dart';

void main() {
  test('a style edited through the controller persists and re-seeds', () async {
    final store = ToolStyleStore(FakeStore());

    final map = await store.load();
    final c = EditorController(toolStyles: map);
    c.selectTool(ToolKind.rectangle);
    c.setColor(const Color(0xFF00FF00));
    await store.save(c.toolStyles); // host persists on change
    c.dispose();

    final reloaded = await store.load();
    final c2 = EditorController(toolStyles: reloaded);
    c2.selectTool(ToolKind.rectangle);
    expect(c2.style.value.color, const Color(0xFF00FF00));
    c2.dispose();
  });
}
