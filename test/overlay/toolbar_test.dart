import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/editor_controller.dart';
import 'package:glimpr/editor/tool_meta.dart';
import 'package:glimpr/overlay/toolbar.dart';
import 'package:glimpr/shortcuts/hotkey_binding.dart';
import 'package:glimpr/shortcuts/shortcut_actions.dart';

// Pumps a toolbar with the given editor bindings. The default tool is Crop,
// which has no options row, so the ONLY Text widgets are the per-tool badges —
// letting tests count badges by Text count.
Future<EditorController> _pumpToolbar(
  WidgetTester tester,
  Map<String, HotkeyBinding?> bindings,
) async {
  final c = EditorController();
  addTearDown(c.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: EditorToolbar(
          controller: c,
          onMove: (_) {},
          onPtEditingDone: () {},
          editorBindings: bindings,
        ),
      ),
    ),
  );
  return c;
}

/// Smoke test: the toolbar must build all tool buttons (catches a bad IconData)
/// and rebuild the contextual options row for EVERY tool without throwing
/// (exercises each ToolKind branch in the options row, incl. text/step font).
void main() {
  testWidgets('builds every tool and every tool options row', (tester) async {
    final c = await _pumpToolbar(tester, kDefaultBindings);

    expect(kEditorToolMeta.length, 12);
    expect(find.byType(IconButton), findsNWidgets(12));

    for (final (kind, _) in kEditorToolMeta) {
      c.selectTool(kind);
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'options row for $kind');
    }
  });

  testWidgets('badges render each tool\'s default binding label',
      (tester) async {
    await _pumpToolbar(tester, kDefaultBindings);

    // Default tool is Crop => no options row => the 12 Text widgets are exactly
    // the 12 tool badges (one per tool, all default-bound).
    expect(find.byType(Text), findsNWidgets(12));
    // Crop's default is bare 'C'; Rectangle's is bare '1'. Both are
    // host-platform-stable (no modifier glyphs).
    expect(find.text('C'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('5'), findsOneWidget); // Pen
  });

  testWidgets('badges track a rebound (custom) binding', (tester) async {
    // Rebind Crop from bare 'C' to bare 'X'; its badge must follow.
    final bindings = {
      ...kDefaultBindings,
      kEditorToolActionKey[ToolKind.crop]!: const HotkeyBinding(
        physicalKey: PhysicalKeyboardKey.keyX,
        logicalKey: LogicalKeyboardKey.keyX,
        modifiers: {},
      ),
    };
    await _pumpToolbar(tester, bindings);

    expect(find.text('X'), findsOneWidget); // the rebound label shows
    expect(find.text('C'), findsNothing); // the old label is gone
    expect(find.byType(Text), findsNWidgets(12)); // still one badge per tool
  });

  testWidgets('an unbound tool shows no badge (button still builds)',
      (tester) async {
    // Map Crop's action to null (unbound) — its badge must disappear while the
    // tool button still builds.
    final bindings = {
      ...kDefaultBindings,
      kEditorToolActionKey[ToolKind.crop]!: null,
    };
    await _pumpToolbar(tester, bindings);

    expect(find.byType(IconButton), findsNWidgets(12)); // all 12 buttons build
    expect(find.text('C'), findsNothing); // crop's badge is suppressed
    expect(find.byType(Text), findsNWidgets(11)); // exactly one fewer badge
  });

  testWidgets('empty bindings => no badges at all', (tester) async {
    await _pumpToolbar(tester, const {});

    expect(find.byType(IconButton), findsNWidgets(12));
    expect(find.byType(Text), findsNothing);
  });
}
