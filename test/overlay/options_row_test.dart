import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/editor_controller.dart';
import 'package:glimpr/overlay/toolbar.dart';

Widget _host(EditorController c) => MaterialApp(
      home: Scaffold(
        body: EditorToolbar(
          controller: c,
          onMove: (_) {},
          onPtEditingDone: () {},
        ),
      ),
    );

void main() {
  testWidgets('font button shows only for the Text tool', (t) async {
    final c = EditorController();
    c.selectTool(ToolKind.rectangle);
    await t.pumpWidget(_host(c));
    expect(find.byKey(const ValueKey('font-button')), findsNothing);
    c.selectTool(ToolKind.text);
    await t.pumpWidget(_host(c));
    expect(find.byKey(const ValueKey('font-button')), findsOneWidget);
  });

  testWidgets('stroke slider shows for stroke tools, hidden for text', (t) async {
    final c = EditorController();
    c.selectTool(ToolKind.rectangle);
    await t.pumpWidget(_host(c));
    expect(find.byKey(const ValueKey('stroke-slider')), findsOneWidget);
    c.selectTool(ToolKind.text);
    await t.pumpWidget(_host(c));
    expect(find.byKey(const ValueKey('stroke-slider')), findsNothing);
  });

  testWidgets('reset-this-tool restores the default style', (t) async {
    final c = EditorController();
    c.selectTool(ToolKind.rectangle);
    c.setStrokeWidth(20);
    await t.pumpWidget(_host(c));
    await t.tap(find.byKey(const ValueKey('reset-tool')));
    await t.pump();
    expect(c.style.value.strokeWidth, 4); // the factory default stroke width
  });
}
