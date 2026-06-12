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

    expect(kEditorToolMeta.length, 15);
    expect(find.byType(IconButton), findsNWidgets(15));

    for (final (kind, _) in kEditorToolMeta) {
      c.selectTool(kind);
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'options row for $kind');
    }
  });

  testWidgets('badges render each tool\'s default binding label',
      (tester) async {
    await _pumpToolbar(tester, kDefaultBindings);

    // Default tool is Crop => no options row => the 15 Text widgets are exactly
    // the 15 tool badges (one per tool, all default-bound).
    expect(find.byType(Text), findsNWidgets(15));
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
    expect(find.byType(Text), findsNWidgets(15)); // still one badge per tool
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

    expect(find.byType(IconButton), findsNWidgets(15)); // all 15 buttons build
    expect(find.text('C'), findsNothing); // crop's badge is suppressed
    expect(find.byType(Text), findsNWidgets(14)); // exactly one fewer badge
  });

  testWidgets('empty bindings => no badges at all', (tester) async {
    await _pumpToolbar(tester, const {});

    expect(find.byType(IconButton), findsNWidgets(15));
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('every tool button has a tooltip with the shared tool label',
      (tester) async {
    await _pumpToolbar(tester, kDefaultBindings);

    // toolLabel is the SAME source the Settings > Shortcuts rows render, so
    // the tooltip text can never drift from the shortcut row's title.
    for (final (kind, _) in kEditorToolMeta) {
      expect(find.byTooltip(toolLabel(kind)), findsOneWidget,
          reason: 'tooltip for $kind');
    }
  });

  testWidgets('pin mode renames the crop slot tooltip to Pin', (tester) async {
    // Wide surface: pin mode adds the in-bar Pin chip and the full bar
    // exceeds the 800px default test width.
    tester.view.physicalSize = const Size(1600, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = EditorController();
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditorToolbar(
            controller: c,
            onMove: (_) {},
            onPtEditingDone: () {},
            editorBindings: kDefaultBindings,
            pinMode: true,
          ),
        ),
      ),
    );

    // The crop slot IS the pin region selector in pin mode.
    expect(find.byTooltip('Pin'), findsOneWidget);
    expect(find.byTooltip('Crop'), findsNothing);
    // Every other tool keeps its normal label.
    expect(find.byTooltip('Rectangle'), findsOneWidget);
  });

  testWidgets(
      'one caption line below the bar; the bottom-anchored bar never moves',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = EditorController();
    addTearDown(c.dispose);
    // Bottom-anchor like the overlay host. The caption space below the bar is
    // exactly ONE line: pin + layer messages merge into a single bar there,
    // painted via zero-height overflow so the tool row never moves.
    Future<void> pump(
            {String? caption, bool accent = false, bool pin = false}) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Stack(
                children: [
                  Positioned(
                    left: 0,
                    bottom: 120,
                    child: Material(
                      type: MaterialType.transparency,
                      child: EditorToolbar(
                        controller: c,
                        onMove: (_) {},
                        onPtEditingDone: () {},
                        editorBindings: const {},
                        pinMode: pin,
                        layerCaption: caption,
                        layerAccent: accent,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

    await pump();
    expect(find.byIcon(Icons.layers), findsNothing);
    final barAt = tester.getTopLeft(find.byType(IconButton).first);
    final barBottom = tester.getBottomLeft(find.byType(IconButton).first).dy;

    await pump(caption: 'Layers: 2/3');
    expect(find.text('Layers: 2/3'), findsOneWidget);
    expect(find.byIcon(Icons.layers), findsOneWidget);
    // The bar did not move; the caption sits BELOW the bar's bottom edge.
    expect(tester.getTopLeft(find.byType(IconButton).first), barAt);
    expect(tester.getTopLeft(find.text('Layers: 2/3')).dy,
        greaterThan(barBottom));

    await pump(caption: 'Layer replaced (1/1)', accent: true);
    expect(find.text('Layer replaced (1/1)'), findsOneWidget);
    expect(tester.getTopLeft(find.byType(IconButton).first), barAt);

    // Pin + layer captions merge into the SAME single line (one bar).
    await pump(pin: true, caption: 'Layers: 2/3');
    expect(tester.getTopLeft(find.byType(IconButton).first), barAt);
    final pinDy = tester
        .getCenter(find.text('Pin mode: the selection floats as a pin'))
        .dy;
    final layerDy = tester.getCenter(find.text('Layers: 2/3')).dy;
    expect(pinDy, layerDy);
    expect(pinDy, greaterThan(barBottom));
  });

  test('the Settings row label combines both crop-slot contexts', () {
    expect(toolSettingsLabel(ToolKind.crop), 'Crop / Pin');
    expect(toolLabel(ToolKind.crop), 'Crop');
    expect(toolLabel(ToolKind.crop, pinMode: true), 'Pin');
    // Every other tool's Settings row matches its tooltip exactly.
    for (final (kind, _) in kEditorToolMeta) {
      if (kind == ToolKind.crop) continue;
      expect(toolSettingsLabel(kind), toolLabel(kind));
      expect(toolLabel(kind, pinMode: true), toolLabel(kind));
    }
  });
}
