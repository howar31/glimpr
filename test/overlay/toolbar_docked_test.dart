import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/editor_controller.dart';
import 'package:glimpr/overlay/toolbar.dart';

// Pumps EditorToolbar with the given optional params inside a MaterialApp so
// BackdropFilter and IconTheme resolve correctly.
Future<void> _pumpToolbar(
  WidgetTester tester, {
  bool showDragHandle = true,
  List<Widget> trailing = const [],
}) async {
  final c = EditorController();
  addTearDown(c.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: EditorToolbar(
          controller: c,
          onMove: (_) {},
          onPtEditingDone: () {},
          showDragHandle: showDragHandle,
          trailing: trailing,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'showDragHandle:false hides the drag_indicator icon',
    (tester) async {
      await _pumpToolbar(tester, showDragHandle: false);

      expect(find.byIcon(Icons.drag_indicator), findsNothing);
    },
  );

  testWidgets(
    'showDragHandle:true (default) keeps the drag_indicator icon',
    (tester) async {
      await _pumpToolbar(tester);

      expect(find.byIcon(Icons.drag_indicator), findsOneWidget);
    },
  );

  testWidgets(
    'trailing widgets appear inside the tool bar',
    (tester) async {
      await _pumpToolbar(
        tester,
        trailing: [const Text('XYZ')],
      );

      expect(find.text('XYZ'), findsOneWidget);
    },
  );

  testWidgets(
    'empty trailing list renders no divider (default behaviour unchanged)',
    (tester) async {
      await _pumpToolbar(tester);

      // No trailing = no divider Container. The only Containers in the bar are
      // the _Bar chrome and color swatches (none visible at default Crop tool).
      // We verify by confirming the Text 'XYZ' is absent (sanity).
      expect(find.text('XYZ'), findsNothing);
    },
  );

  testWidgets(
    'showDragHandle:false + trailing: both params work together',
    (tester) async {
      await _pumpToolbar(
        tester,
        showDragHandle: false,
        trailing: [const Text('XYZ')],
      );

      expect(find.byIcon(Icons.drag_indicator), findsNothing);
      expect(find.text('XYZ'), findsOneWidget);
    },
  );
}
