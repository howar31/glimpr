import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/editor_controller.dart';
import 'package:glimpr/overlay/toolbar.dart';

/// Smoke test: the toolbar must build all tool buttons (catches a bad IconData)
/// and rebuild the contextual options row for EVERY tool without throwing
/// (exercises each ToolKind branch in the options row, incl. text/step font).
void main() {
  testWidgets('builds every tool and every tool options row', (tester) async {
    final c = EditorController();
    addTearDown(c.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditorToolbar(
            controller: c,
            onMove: (_) {},
            onPtEditingDone: () {},
          ),
        ),
      ),
    );

    expect(EditorToolbar.tools.length, 12);
    expect(find.byType(IconButton), findsNWidgets(12));

    for (final (kind, _, _) in EditorToolbar.tools) {
      c.selectTool(kind);
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'options row for $kind');
    }
  });
}
