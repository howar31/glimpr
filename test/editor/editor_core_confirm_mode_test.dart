import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/crop_confirm_mode.dart';

import '../support/fake_editor_host.dart';

/// The per-surface crop confirm mode: `release` commits the moment the drag
/// ends (the overlay's original behaviour); `adjust` leaves an editable
/// pending selection (the editor's original behaviour). Both hosts are
/// exercised in BOTH modes.
void main() {
  late ui.Image overlayImage;
  late ui.Image editorImage;

  setUpAll(() async {
    overlayImage = await makeBaseImage(800, 600);
    editorImage = await makeBaseImage(704, 504);
  });

  FakeEditorHost overlayHost(CropConfirmMode mode) => FakeEditorHost(
        baseImage: overlayImage,
        cropConfirm: mode,
      );

  // Image-editor shape (see editor_core_trim_test.dart): 704x504 fits the
  // 800x600 window at scale 1.0 with a (48,48) viewport translation.
  const vp = Offset(48, 48);
  FakeEditorHost editorHost(CropConfirmMode mode) => FakeEditorHost(
        baseImage: editorImage,
        size: const Size(704, 504),
        viewportInteractive: true,
        cropTrims: true,
        rightClickExits: false,
        cropConfirm: mode,
      );

  Future<void> drag(WidgetTester tester, Offset from, Offset to,
      {Offset offset = Offset.zero}) async {
    final g = await tester.startGesture(from + offset);
    await g.moveTo(to + offset);
    await tester.pump();
    await g.up();
    await tester.pump();
  }

  group('overlay host (export) in ADJUST mode', () {
    testWidgets('release leaves a pending box: chrome shown, nothing exported',
        (tester) async {
      final host = overlayHost(CropConfirmMode.adjust);
      await pumpEditorCore(tester, host);
      await drag(tester, const Offset(100, 100), const Offset(250, 200));
      expect(host.exports, isEmpty);
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
    });

    testWidgets('Enter exports the pending rect (inclusive endpoints)',
        (tester) async {
      final host = overlayHost(CropConfirmMode.adjust);
      await pumpEditorCore(tester, host);
      await drag(tester, const Offset(100, 100), const Offset(250, 200));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(host.exports.single.rect, const Rect.fromLTRB(100, 100, 251, 201));
    });

    testWidgets('the on-canvas check exports; a corner drag resizes first',
        (tester) async {
      final host = overlayHost(CropConfirmMode.adjust);
      await pumpEditorCore(tester, host);
      await drag(tester, const Offset(100, 100), const Offset(250, 200));
      // Drag the bottom-right handle (at the inclusive edge 251,201) outward.
      await drag(tester, const Offset(251, 201), const Offset(301, 251));
      expect(host.exports, isEmpty);
      await tester.tap(find.byIcon(Icons.check));
      await tester.pump();
      expect(host.exports.single.rect, const Rect.fromLTRB(100, 100, 301, 251));
    });

    testWidgets('Esc clears the pending box; a second Esc cancels the capture',
        (tester) async {
      final host = overlayHost(CropConfirmMode.adjust);
      await pumpEditorCore(tester, host);
      await drag(tester, const Offset(100, 100), const Offset(250, 200));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byIcon(Icons.check), findsNothing);
      expect(host.cancelCount, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(host.cancelCount, 1);
      expect(host.exports, isEmpty);
    });

    testWidgets('a bare tap outside the pending box clears it, no export',
        (tester) async {
      final host = overlayHost(CropConfirmMode.adjust);
      await pumpEditorCore(tester, host);
      await drag(tester, const Offset(100, 100), const Offset(250, 200));
      await tester.tapAt(const Offset(600, 500));
      await tester.pump();
      expect(find.byIcon(Icons.check), findsNothing);
      expect(host.exports, isEmpty);
      // With no pending box a tap is the snap-capture again (whole display).
      await tester.tapAt(const Offset(600, 500));
      await tester.pump();
      expect(host.exports, hasLength(1));
    });

    testWidgets('a too-small drag is discarded', (tester) async {
      final host = overlayHost(CropConfirmMode.adjust);
      await pumpEditorCore(tester, host);
      // Past the pan slop horizontally but only 1px tall -> invalid (< 2x2).
      await drag(tester, const Offset(100, 100), const Offset(150, 100));
      expect(find.byIcon(Icons.check), findsNothing);
      expect(host.exports, isEmpty);
    });
  });

  group('overlay host in RELEASE mode (unchanged default)', () {
    testWidgets('release exports at once, no confirm chrome', (tester) async {
      final host = overlayHost(CropConfirmMode.release);
      await pumpEditorCore(tester, host);
      await drag(tester, const Offset(100, 100), const Offset(250, 200));
      expect(host.exports.single.rect, const Rect.fromLTRB(100, 100, 251, 201));
      expect(find.byIcon(Icons.check), findsNothing);
    });
  });

  group('editor host (trim) in RELEASE mode', () {
    testWidgets('release trims at once: no confirm chrome, canvas trimmed',
        (tester) async {
      final host = editorHost(CropConfirmMode.release);
      final c = await pumpEditorCore(tester, host);
      final g = await tester.startGesture(const Offset(100, 100) + vp);
      await g.moveTo(const Offset(300, 300) + vp);
      await tester.pump();
      // The trim rasterises (picture.toImage), which never completes in the
      // fake-async zone: release inside runAsync and poll for the result.
      await tester.runAsync(() async {
        await g.up();
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (c.document.value.canvasSize == null &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pump();
      expect(find.byIcon(Icons.check), findsNothing);
      expect(c.document.value.canvasSize, const Size(201, 201));
      expect(host.exports, isEmpty);
    });
  });

  group('editor host in ADJUST mode (unchanged default)', () {
    testWidgets('release leaves the pending trim with confirm chrome',
        (tester) async {
      final host = editorHost(CropConfirmMode.adjust);
      final c = await pumpEditorCore(tester, host);
      await drag(tester, const Offset(100, 100), const Offset(300, 300),
          offset: vp);
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(c.document.value.canvasSize, isNull);
    });
  });
}
