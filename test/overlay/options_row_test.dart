import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/l10n/gen/app_localizations.dart';
import 'package:glimpr/editor/editor_controller.dart';
import 'package:glimpr/overlay/toolbar.dart';

Widget _host(EditorController c) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: EditorToolbar(controller: c, onMove: (_) {}, onPtEditingDone: () {}),
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

  testWidgets('stroke stepper shows for stroke tools, hidden for text', (
    t,
  ) async {
    final c = EditorController();
    c.selectTool(ToolKind.rectangle);
    await t.pumpWidget(_host(c));
    expect(find.byKey(const ValueKey('stroke-stepper')), findsOneWidget);
    c.selectTool(ToolKind.text);
    await t.pumpWidget(_host(c));
    expect(find.byKey(const ValueKey('stroke-stepper')), findsNothing);
  });

  testWidgets(
    'committing the stroke field hands keyboard focus back to the host',
    (t) async {
      // Bug: typing a stroke width then committing (Enter / submit / tap-out)
      // left the editor without keyboard focus, so tool-switch shortcuts died.
      // The stroke stepper must notify the host (onPtEditingDone) on commit so
      // it can re-focus the editor — same as the font-size stepper already does.
      final c = EditorController();
      c.selectTool(ToolKind.rectangle);
      var commits = 0;
      await t.pumpWidget(
        MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: EditorToolbar(
              controller: c,
              onMove: (_) {},
              onPtEditingDone: () => commits++,
            ),
          ),
        ),
      );
      final field = find.descendant(
        of: find.byKey(const ValueKey('stroke-stepper')),
        matching: find.byType(TextField),
      );
      await t.tap(field);
      await t.pump();
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pump();
      expect(commits, 1);
    },
  );

  testWidgets('number field rejects non-digit characters', (t) async {
    // The stepper is a number field: typing letters must be filtered out so the
    // value stays numeric (the field used to accept "dfsda").
    final c = EditorController();
    c.selectTool(ToolKind.rectangle);
    await t.pumpWidget(_host(c));
    final field = find.descendant(
      of: find.byKey(const ValueKey('stroke-stepper')),
      matching: find.byType(TextField),
    );
    await t.enterText(field, '1a2b3');
    await t.pump();
    expect(t.widget<TextField>(field).controller!.text, '123');
  });

  testWidgets('committing an out-of-range value snaps the field to the limit', (
    t,
  ) async {
    // Typing past the max (e.g. 1213 for a 1..40 stroke) clamps the applied
    // value live, but the field text must also snap back to the limit on commit
    // instead of showing the raw out-of-range number.
    final c = EditorController();
    c.selectTool(ToolKind.rectangle);
    await t.pumpWidget(_host(c));
    final field = find.descendant(
      of: find.byKey(const ValueKey('stroke-stepper')),
      matching: find.byType(TextField),
    );
    await t.enterText(field, '1213');
    await t.pump();
    await t.testTextInput.receiveAction(TextInputAction.done);
    await t.pump();
    expect(t.widget<TextField>(field).controller!.text, '40'); // kStrokeMax
    expect(c.style.value.strokeWidth, 40);
  });

  testWidgets('texture picker shows only for the highlighter', (t) async {
    final c = EditorController();
    c.selectTool(ToolKind.rectangle);
    await t.pumpWidget(_host(c));
    expect(find.byKey(const ValueKey('texture-picker')), findsNothing);
    c.selectTool(ToolKind.highlighter);
    await t.pumpWidget(_host(c));
    expect(find.byKey(const ValueKey('texture-picker')), findsOneWidget);
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
