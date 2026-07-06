import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/draw_style.dart';
import 'package:glimpr/editor/drawable.dart';
import 'package:glimpr/editor/editor_controller.dart';

import '../support/fake_editor_host.dart';

// Image-editor shape: the 704x504 canvas fits the 800x600 window at the
// initial-fit margin (48) EXACTLY at scale 1.0, so the viewport is a pure
// (48,48) translation and screen coords == logical + 48.
const canvasSize = Size(704, 504);
const vp = Offset(48, 48);

void main() {
  late ui.Image baseImage;

  setUpAll(() async {
    baseImage = await makeBaseImage(704, 504);
  });

  FakeEditorHost editorHost() => FakeEditorHost(
        baseImage: baseImage,
        size: canvasSize,
        viewportInteractive: true,
        cropTrims: true,
        rightClickExits: false,
      );

  Future<void> dragSelect(WidgetTester tester, Offset from, Offset to) async {
    final g = await tester.startGesture(from + vp);
    await g.moveTo(to + vp);
    await tester.pump();
    await g.up();
    await tester.pump();
  }

  /// Confirms the pending trim with Enter INSIDE runAsync: _confirmTrim's
  /// picture.toImage never completes in the fake-async test zone, so the key
  /// event (and everything it kicks off) must run real-async. Uses the raw
  /// key simulator — the guarded tester.sendKeyEvent cannot nest in runAsync.
  Future<void> confirmTrim(WidgetTester tester, EditorController c) async {
    await tester.runAsync(() async {
      await simulateKeyDownEvent(LogicalKeyboardKey.enter);
      await simulateKeyUpEvent(LogicalKeyboardKey.enter);
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (c.document.value.canvasSize == null &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
  }

  testWidgets('crop drag leaves a PENDING selection: confirm chrome shows, '
      'nothing is committed or exported', (tester) async {
    final host = editorHost();
    final c = await pumpEditorCore(tester, host);

    await dragSelect(tester, const Offset(100, 100), const Offset(300, 300));

    expect(find.byIcon(Icons.check), findsOneWidget); // on-canvas confirm
    expect(find.byIcon(Icons.close), findsOneWidget); // on-canvas cancel
    expect(host.exports, isEmpty); // the editor's crop never exports
    expect(c.document.value.canvasSize, isNull); // not trimmed yet
  });

  testWidgets('Enter confirms the trim: canvas set, drawables shifted, '
      'and one undo restores everything', (tester) async {
    final host = editorHost();
    final c = await pumpEditorCore(tester, host);
    c.commitDrawable(const RectangleDrawable(
        Rect.fromLTRB(120, 120, 160, 160), DrawStyle()));
    await tester.pump();

    await dragSelect(tester, const Offset(100, 100), const Offset(300, 300));
    await confirmTrim(tester, c);

    expect(c.document.value.canvasSize, const Size(200, 200));
    expect(c.document.value.canvasImage, isNotNull);
    final shifted = c.document.value.drawables.single as RectangleDrawable;
    expect(shifted.rect, const Rect.fromLTRB(20, 20, 60, 60));
    expect(host.exports, isEmpty);

    expect(c.document.value.canUndo, isTrue);
    c.undo();
    expect(c.document.value.canvasSize, isNull); // pre-trim canvas restored
    final restored = c.document.value.drawables.single as RectangleDrawable;
    expect(restored.rect, const Rect.fromLTRB(120, 120, 160, 160));
  });

  testWidgets('Esc clears the pending selection; only a second Esc closes',
      (tester) async {
    final host = editorHost();
    await pumpEditorCore(tester, host);

    await dragSelect(tester, const Offset(100, 100), const Offset(300, 300));
    expect(find.byIcon(Icons.check), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byIcon(Icons.check), findsNothing);
    expect(host.cancelCount, 0); // still in the editor

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(host.cancelCount, 1);
  });

  testWidgets('the on-canvas X cancels the pending selection', (tester) async {
    final host = editorHost();
    final c = await pumpEditorCore(tester, host);

    await dragSelect(tester, const Offset(100, 100), const Offset(300, 300));
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();

    expect(find.byIcon(Icons.check), findsNothing);
    expect(c.document.value.canvasSize, isNull);
    expect(host.exports, isEmpty);
    expect(host.cancelCount, 0);
  });

  testWidgets('a pending selection can be MOVED before confirming',
      (tester) async {
    final host = editorHost();
    final c = await pumpEditorCore(tester, host);
    c.commitDrawable(const RectangleDrawable(
        Rect.fromLTRB(160, 140, 180, 160), DrawStyle()));
    await tester.pump();

    await dragSelect(tester, const Offset(100, 100), const Offset(300, 300));
    // Press INSIDE the pending rect and drag: the whole selection moves.
    await dragSelect(tester, const Offset(200, 200), const Offset(250, 230));
    await confirmTrim(tester, c);

    // Selection moved by (50,30) -> trim origin (150,130), size unchanged.
    expect(c.document.value.canvasSize, const Size(200, 200));
    final shifted = c.document.value.drawables.single as RectangleDrawable;
    expect(shifted.rect, const Rect.fromLTRB(10, 10, 30, 30));
  });

  testWidgets('a pending selection can be corner-RESIZED before confirming',
      (tester) async {
    final host = editorHost();
    final c = await pumpEditorCore(tester, host);

    await dragSelect(tester, const Offset(100, 100), const Offset(300, 300));
    // Grab the bottom-right handle of the pending rect and grow it.
    await dragSelect(tester, const Offset(300, 300), const Offset(350, 350));
    await confirmTrim(tester, c);

    expect(c.document.value.canvasSize, const Size(250, 250));
  });
}
