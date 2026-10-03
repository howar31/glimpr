import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/capture/captured_display.dart' show SnapWindow;
import 'package:glimpr/capture/element_snap.dart';
import 'package:glimpr/editor/drawable.dart';
import 'package:glimpr/editor/editor_controller.dart';
import 'package:glimpr/overlay/crop_hud.dart';

import '../support/fake_editor_host.dart';

// The snap tools whose TAP commits a drawable (crop exports instead). Both the
// window-snap and the element-snap expectations run over this list.
const kDrawableSnapTools = [
  ToolKind.blur,
  ToolKind.pixelate,
  ToolKind.rectangle,
  ToolKind.ellipse,
  ToolKind.spotlight,
];

// Capture-time windows, front-to-back: A is topmost and overlaps B.
const winARect = Rect.fromLTRB(50, 50, 400, 300);
const winBRect = Rect.fromLTRB(200, 100, 700, 500);
const windows = [
  SnapWindow(rect: winARect, title: 'Front', app: 'AppA', windowId: 11),
  SnapWindow(rect: winBRect, title: 'Back', app: 'AppB', windowId: 22),
];

/// The snap-highlight rect currently painted, or null when no highlight shows.
Rect? highlightRect(WidgetTester tester) {
  for (final p in tester.widgetList<CustomPaint>(find.byType(CustomPaint))) {
    if (p.painter is WindowHighlightPainter) {
      return (p.painter as WindowHighlightPainter).rect;
    }
  }
  return null;
}

Future<TestGesture> mousePointer(WidgetTester tester) async {
  final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await g.addPointer(location: Offset.zero);
  addTearDown(g.removePointer);
  return g;
}

void main() {
  late ui.Image baseImage;

  setUpAll(() async {
    baseImage = await makeBaseImage(800, 600);
  });

  group('window snap', () {
    testWidgets('hovering highlights the TOPMOST window under the cursor',
        (tester) async {
      final host = FakeEditorHost(baseImage: baseImage, snapWindows: windows);
      await pumpEditorCore(tester, host);

      final mouse = await mousePointer(tester);
      await mouse.moveTo(const Offset(250, 150)); // inside A AND B -> A wins
      await tester.pumpAndSettle();
      expect(highlightRect(tester), winARect);

      await mouse.moveTo(const Offset(500, 400)); // inside B only
      await tester.pumpAndSettle();
      expect(highlightRect(tester), winBRect);
    });

    testWidgets('crop over bare desktop highlights the whole display',
        (tester) async {
      final host = FakeEditorHost(baseImage: baseImage, snapWindows: windows);
      await pumpEditorCore(tester, host);

      final mouse = await mousePointer(tester);
      await mouse.moveTo(const Offset(10, 550)); // outside both windows
      await tester.pumpAndSettle();
      // The inset full-display rect (frame kept fully on-screen).
      expect(highlightRect(tester), const Rect.fromLTWH(2, 2, 796, 596));
    });

    testWidgets('crop tap exports the snapped window rect + SnapWindow',
        (tester) async {
      final host = FakeEditorHost(baseImage: baseImage, snapWindows: windows);
      await pumpEditorCore(tester, host);

      await tester.tapAt(const Offset(250, 150));
      await tester.pump();

      expect(host.exports, hasLength(1));
      expect(host.exports.single.rect, winARect);
      expect(host.exports.single.window?.title, 'Front');
      expect(host.exports.single.window?.windowId, 11);
    });

    // Every snap tool that commits a DRAWABLE (crop exports instead) spans the
    // snapped window. Looped so a newly added snap tool has to opt in here too.
    for (final tool in kDrawableSnapTools) {
      testWidgets('${tool.name} tap on a window commits a drawable spanning it',
          (tester) async {
        final host = FakeEditorHost(baseImage: baseImage, snapWindows: windows);
        final c = await pumpEditorCore(tester, host);
        c.selectTool(tool);
        await tester.pump();

        await tester.tapAt(const Offset(500, 400)); // inside B only
        await tester.pump();

        final d = c.document.value.drawables.single as RectShaped;
        expect(d.rect, winBRect);
        expect(host.exports, isEmpty); // annotation, not a capture
      });
    }

    testWidgets('the snap highlight is suppressed while dragging',
        (tester) async {
      final host = FakeEditorHost(baseImage: baseImage, snapWindows: windows);
      await pumpEditorCore(tester, host);

      final mouse = await mousePointer(tester);
      await mouse.moveTo(const Offset(250, 150));
      await tester.pumpAndSettle();
      expect(highlightRect(tester), winARect);

      final g = await tester.startGesture(const Offset(250, 150));
      await g.moveTo(const Offset(300, 220));
      await tester.pump();
      expect(highlightRect(tester), isNull); // mid-drag: no snap frame

      await g.up();
      await tester.pump();
    });
  });

  group('snap size label', () {
    // The loupe column shows the snap candidate's W x H (native px) whenever a
    // snap target is highlighted; it goes with the frame (none while dragging,
    // none without a snap tool) and never shows twice.
    BoxSizeLabel? sizeLabel(WidgetTester tester) {
      final found = find.byType(BoxSizeLabel);
      expect(found.evaluate().length, lessThanOrEqualTo(1));
      return found.evaluate().isEmpty ? null : tester.widget(found);
    }

    testWidgets('hovering a window shows its size in native pixels',
        (tester) async {
      final host = FakeEditorHost(
          baseImage: baseImage, snapWindows: windows, pixelScale: 2.0);
      await pumpEditorCore(tester, host);

      final mouse = await mousePointer(tester);
      await mouse.moveTo(const Offset(250, 150)); // A on top
      await tester.pumpAndSettle();
      final label = sizeLabel(tester);
      expect(label, isNotNull);
      expect(label!.w, (winARect.width * 2).round());
      expect(label.h, (winARect.height * 2).round());
      // It sits on the coordinates' row, to their right.
      final coords = tester.getRect(find.byType(LoupeReadout));
      final size = tester.getRect(find.byType(BoxSizeLabel));
      expect(size.left, greaterThan(coords.right));
      expect(size.center.dy, moreOrLessEquals(coords.center.dy, epsilon: 0.5));

      await mouse.moveTo(const Offset(500, 400)); // B only
      await tester.pumpAndSettle();
      expect(sizeLabel(tester)!.w, (winBRect.width * 2).round());
      expect(sizeLabel(tester)!.h, (winBRect.height * 2).round());
    });

    testWidgets('crop over bare desktop shows the whole display size',
        (tester) async {
      final host = FakeEditorHost(baseImage: baseImage, snapWindows: windows);
      await pumpEditorCore(tester, host);

      final mouse = await mousePointer(tester);
      await mouse.moveTo(const Offset(10, 550)); // outside both windows
      await tester.pumpAndSettle();
      final label = sizeLabel(tester);
      expect(label, isNotNull);
      // A bare-desktop tap exports the WHOLE display (null rect), so the label
      // is the display size, not the inset highlight frame.
      expect(label!.w, 800);
      expect(label.h, 600);
    });

    testWidgets('near the right edge the loupe flips left so the row stays '
        'on-screen', (tester) async {
      final host = FakeEditorHost(baseImage: baseImage, snapWindows: windows);
      await pumpEditorCore(tester, host);

      final mouse = await mousePointer(tester);
      // Bare desktop, where the glass alone would still fit to the right of the
      // cursor but the coordinates + size row would not.
      await mouse.moveTo(const Offset(650, 30));
      await tester.pumpAndSettle();
      final coords = tester.getRect(find.byType(LoupeReadout));
      final size = tester.getRect(find.byType(BoxSizeLabel));
      expect(size.right, lessThanOrEqualTo(800));
      expect(coords.left, greaterThanOrEqualTo(0));
      expect(size.left, greaterThan(coords.right)); // order kept when flipped
    });

    testWidgets('the snap label goes with a non-snap tool and yields to the '
        'drag readout', (tester) async {
      final host = FakeEditorHost(baseImage: baseImage, snapWindows: windows);
      final c = await pumpEditorCore(tester, host);

      final mouse = await mousePointer(tester);
      await mouse.moveTo(const Offset(250, 150));
      await tester.pumpAndSettle();
      expect(sizeLabel(tester), isNotNull);

      // A non-snap tool: no frame, no label.
      c.selectTool(ToolKind.pen);
      await mouse.moveTo(const Offset(252, 152));
      await tester.pumpAndSettle();
      expect(highlightRect(tester), isNull);
      expect(sizeLabel(tester), isNull);

      // Back on a snap tool the label returns with the frame.
      c.selectTool(ToolKind.crop);
      await mouse.moveTo(const Offset(250, 150));
      await tester.pumpAndSettle();
      expect(highlightRect(tester), winARect);
      expect(sizeLabel(tester), isNotNull);

      // Mid-drag the snap frame is gone and so is its label; the ONE label left
      // is the drag readout's own W x H (the ~50x70 drag box, pixel-inclusive,
      // not window A's 350x250).
      final g = await tester.startGesture(const Offset(250, 150));
      await g.moveTo(const Offset(300, 220));
      await tester.pump();
      expect(highlightRect(tester), isNull);
      final dragLabel = sizeLabel(tester);
      expect(dragLabel, isNotNull);
      expect(dragLabel!.w, inInclusiveRange(50, 51));
      expect(dragLabel.h, inInclusiveRange(70, 71));
      await g.up();
      await tester.pump();
    });
  });

  group('element snap plumbing', () {
    // A configurable element-snap host: [calls] records every (point, walk)
    // query; [reply] builds the response (null = fall back to window snap).
    (FakeEditorHost, List<({Offset p, int walk})>) elementHost(
        ElementSnap? Function(Offset p, int walk) reply) {
      final calls = <({Offset p, int walk})>[];
      final host = FakeEditorHost(
        baseImage: baseImage,
        snapWindows: windows,
        elementSnapAt: (p, {walk = 0}) {
          calls.add((p: p, walk: walk));
          return Future.value(reply(p, walk));
        },
      );
      return (host, calls);
    }

    ElementSnap element(Rect rect, {int appliedWalk = 0}) => ElementSnap(
          rect: rect,
          role: 'AXButton',
          title: 'OK Button',
          app: 'AppA',
          latencyUs: 100,
          appliedWalk: appliedWalk,
        );

    const elRect = Rect.fromLTRB(240, 140, 320, 190);

    testWidgets('hover queries the host at the hovered point (walk 0) and the '
        'returned element refines the snap rect', (tester) async {
      final (host, calls) = elementHost((p, walk) => element(elRect));
      await pumpEditorCore(tester, host);

      final mouse = await mousePointer(tester);
      await mouse.moveTo(const Offset(250, 150));
      await tester.pumpAndSettle(); // flush the async reply + tween

      expect(calls, hasLength(1));
      expect(calls.single.p, const Offset(250, 150));
      expect(calls.single.walk, 0);
      expect(highlightRect(tester), elRect); // element beats the window rect
    });

    testWidgets('a null element reply falls back to the window snap',
        (tester) async {
      final (host, calls) = elementHost((p, walk) => null);
      await pumpEditorCore(tester, host);

      final mouse = await mousePointer(tester);
      await mouse.moveTo(const Offset(250, 150));
      await tester.pumpAndSettle();

      expect(calls, hasLength(1));
      expect(highlightRect(tester), winARect);
    });

    testWidgets("'.' grows / ',' shrinks the walk; the counter re-syncs to "
        'appliedWalk from each reply', (tester) async {
      var echoApplied = true; // reply echoes the requested walk back
      final (host, calls) = elementHost(
          (p, walk) => element(elRect, appliedWalk: echoApplied ? walk : 0));
      await pumpEditorCore(tester, host);

      final mouse = await mousePointer(tester);
      await mouse.moveTo(const Offset(250, 150)); // establish the hover
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.period); // grow
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.period);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.comma); // shrink
      await tester.pump();

      // Native now reports the walk pinned at the root (appliedWalk 0): the
      // counter must clamp back so the next step is 0+1, not a runaway +1.
      echoApplied = false;
      await tester.sendKeyEvent(LogicalKeyboardKey.period);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.period);
      await tester.pump();

      expect(calls.map((c) => c.walk).toList(), [0, 1, 2, 1, 2, 1]);
    });

    testWidgets('the mouse wheel walks one level per event (up = grow)',
        (tester) async {
      final (host, calls) =
          elementHost((p, walk) => element(elRect, appliedWalk: walk));
      await pumpEditorCore(tester, host);

      final tp = TestPointer(9, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(tp.hover(const Offset(250, 150)));
      await tester.pumpAndSettle(); // establish the hover element (walk 0)
      expect(calls.map((c) => c.walk).toList(), [0]);

      await tester.sendEventToBinding(tp.scroll(const Offset(0, -120)));
      await tester.pumpAndSettle();

      expect(calls.map((c) => c.walk).toList(), [0, 1]);
    });

    testWidgets('confirm exports the element rect with a synthesized window '
        '(rectangular crop: no windowId)', (tester) async {
      final (host, _) = elementHost((p, walk) => element(elRect));
      await pumpEditorCore(tester, host);

      final mouse = await mousePointer(tester);
      await mouse.moveTo(const Offset(250, 150));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(host.exports, hasLength(1));
      expect(host.exports.single.rect, elRect);
      final w = host.exports.single.window!;
      expect(w.title, 'OK Button');
      expect(w.app, 'AppA');
      expect(w.windowId, isNull); // element commits are rectangular crops
    });

    // The window-snap loop's element counterpart: a tool wired into the snap
    // pipeline (highlight + tree-walk) must COMMIT what the highlight showed —
    // the element when one resolved, not the raw window rect underneath it.
    for (final tool in kDrawableSnapTools) {
      testWidgets('${tool.name} tap commits the ELEMENT rect, not the window',
          (tester) async {
        final (host, _) = elementHost((p, walk) => element(elRect));
        final c = await pumpEditorCore(tester, host);
        c.selectTool(tool);
        await tester.pump();

        final mouse = await mousePointer(tester);
        await mouse.moveTo(const Offset(250, 150)); // inside elRect and winA
        await tester.pumpAndSettle(); // flush the async element reply
        expect(highlightRect(tester), elRect);

        await tester.tapAt(const Offset(250, 150));
        await tester.pump();

        final d = c.document.value.drawables.single as RectShaped;
        expect(d.rect, elRect);
      });
    }

    testWidgets('switching to a non-snap tool drops the highlight',
        (tester) async {
      final (host, _) = elementHost((p, walk) => element(elRect));
      final c = await pumpEditorCore(tester, host);

      final mouse = await mousePointer(tester);
      await mouse.moveTo(const Offset(250, 150));
      await tester.pumpAndSettle();
      expect(highlightRect(tester), elRect);

      c.selectTool(ToolKind.text); // text never snaps
      await tester.pumpAndSettle();
      expect(highlightRect(tester), isNull);
    });
  });
}
