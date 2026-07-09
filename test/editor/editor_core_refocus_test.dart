import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/editor_controller.dart';

import '../support/fake_editor_host.dart';

// EditorController.requestFocus() is the hand-back path a docked toolbar's
// number field uses after it commits (the standalone image editor wires
// onPtEditingDone to it): EditorCore must re-acquire its key-handling focus so
// tool shortcuts keep working — WITHOUT stealing focus from the inline text
// editor when one is open. The bare `tester.pump()`s after requestFocus also
// pin the ensureVisualUpdate behavior: the post-frame hand-back must run even
// when nothing else has scheduled a frame.
void main() {
  late ui.Image baseImage;

  setUpAll(() async {
    baseImage = await makeBaseImage(800, 600);
  });

  testWidgets('requestFocus restores tool shortcuts after focus is orphaned',
      (tester) async {
    final host = FakeEditorHost(baseImage: baseImage);
    final c = await pumpEditorCore(tester, host);

    // Simulate a docked toolbar field commit: focus leaves the editor's node
    // and is NOT handed back (the field just unfocuses itself).
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.pump();
    expect(c.tool.value, isNot(ToolKind.ellipse)); // shortcuts are dead

    // The hand-back path (post-frame) revives them.
    c.requestFocus();
    await tester.pump();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.pump();
    expect(c.tool.value, ToolKind.ellipse);
  });

  testWidgets('requestFocus while editing text keeps the text field focused',
      (tester) async {
    final host = FakeEditorHost(baseImage: baseImage);
    final c = await pumpEditorCore(tester, host);
    c.selectTool(ToolKind.text);
    await tester.pump();
    await tester.tapAt(const Offset(150, 120));
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);

    // A toolbar field committing mid-text-edit (e.g. the pt stepper) hands
    // focus back via requestFocus: it must return to the INLINE TEXT editor,
    // not the tool-shortcut node — else the next letter switches tools.
    c.requestFocus();
    await tester.pump();
    await tester.pump();
    // Raw key press (enterText would force-focus the field and mask the bug).
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.pump();

    expect(c.tool.value, ToolKind.text); // NOT the blur shortcut
    expect(find.byType(TextField), findsOneWidget);

    // Commit so no inline editor leaks into teardown.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
  });
}
