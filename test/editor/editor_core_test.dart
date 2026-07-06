import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/drawable.dart';
import 'package:glimpr/editor/drawable_painter.dart';
import 'package:glimpr/editor/editor_controller.dart';

import '../support/fake_editor_host.dart';

/// The selection-highlight painter currently on screen, or null when nothing
/// is selected (EditorCore then mounts an empty box instead of the painter).
SelectionHighlightPainter? selectionPainter(WidgetTester tester) {
  for (final p in tester.widgetList<CustomPaint>(find.byType(CustomPaint))) {
    if (p.painter is SelectionHighlightPainter) {
      return p.painter as SelectionHighlightPainter;
    }
  }
  return null;
}

/// Touch-drag from [from] to [to] (optionally via waypoints) — the draw/crop
/// gesture. DragStartBehavior.down means the pan anchors at [from] exactly.
Future<void> drag(
  WidgetTester tester,
  Offset from,
  Offset to, {
  List<Offset> via = const [],
}) async {
  final g = await tester.startGesture(from);
  for (final p in via) {
    await g.moveTo(p);
    await tester.pump();
  }
  await g.moveTo(to);
  await tester.pump();
  await g.up();
  await tester.pump();
}

/// A hovering mouse pointer (no buttons) whose moves drive MouseRegion/hover.
Future<TestGesture> mousePointer(WidgetTester tester) async {
  final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await g.addPointer(location: Offset.zero);
  addTearDown(g.removePointer);
  return g;
}

void main() {
  late ui.Image baseImage;

  setUpAll(() async {
    // Real-async zone: image decode callbacks never fire inside testWidgets.
    baseImage = await makeBaseImage(800, 600);
  });

  group('region selection (overlay crop)', () {
    testWidgets('drag-release exports the logical selection rect',
        (tester) async {
      final host = FakeEditorHost(baseImage: baseImage);
      await pumpEditorCore(tester, host);

      await drag(tester, const Offset(100, 100), const Offset(300, 250),
          via: const [Offset(180, 160)]);

      expect(host.exports, hasLength(1));
      expect(host.exports.single.rect,
          Rect.fromLTRB(100, 100, 300, 250));
      expect(host.exports.single.window, isNull); // no window under cursor
      // The drawing lock wraps the drag exactly once: lock on start, off on end.
      expect(host.cursor.drawingLockCalls, [true, false]);
    });

    testWidgets('a bare tap exports the whole display (null rect)',
        (tester) async {
      final host = FakeEditorHost(baseImage: baseImage);
      await pumpEditorCore(tester, host);

      await tester.tapAt(const Offset(400, 300));
      await tester.pump();

      expect(host.exports, hasLength(1));
      expect(host.exports.single.rect, isNull);
      expect(host.exports.single.window, isNull);
    });

    testWidgets('Esc with no gesture cancels the session', (tester) async {
      final host = FakeEditorHost(baseImage: baseImage);
      await pumpEditorCore(tester, host);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(host.cancelCount, 1);
      expect(host.exports, isEmpty);
    });

    testWidgets('Esc mid-drag cancels only the gesture (no export, no exit)',
        (tester) async {
      final host = FakeEditorHost(baseImage: baseImage);
      await pumpEditorCore(tester, host);

      final g = await tester.startGesture(const Offset(100, 100));
      await g.moveTo(const Offset(250, 200));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(host.cancelCount, 0);
      expect(host.exports, isEmpty);
    });

    testWidgets('right-click exits when rightClickExits is on', (tester) async {
      final host = FakeEditorHost(baseImage: baseImage, rightClickExits: true);
      await pumpEditorCore(tester, host);

      final g = await tester.startGesture(const Offset(400, 300),
          kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(host.cancelCount, 1);
    });

    testWidgets('right-click stays when rightClickExits is off',
        (tester) async {
      final host = FakeEditorHost(baseImage: baseImage, rightClickExits: false);
      await pumpEditorCore(tester, host);

      final g = await tester.startGesture(const Offset(400, 300),
          kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(host.cancelCount, 0);
    });
  });

  group('drawing tools commit the right drawable', () {
    testWidgets('rectangle drag commits a RectangleDrawable', (tester) async {
      final host = FakeEditorHost(baseImage: baseImage);
      final c = await pumpEditorCore(tester, host);
      c.selectTool(ToolKind.rectangle);
      await tester.pump();

      await drag(tester, const Offset(100, 100), const Offset(220, 180));

      final d = c.document.value.drawables.single as RectangleDrawable;
      expect(d.rect, Rect.fromLTRB(100, 100, 220, 180));
    });

    testWidgets('ellipse drag commits an EllipseDrawable', (tester) async {
      final host = FakeEditorHost(baseImage: baseImage);
      final c = await pumpEditorCore(tester, host);
      c.selectTool(ToolKind.ellipse);
      await tester.pump();

      await drag(tester, const Offset(300, 120), const Offset(420, 260));

      final d = c.document.value.drawables.single as EllipseDrawable;
      expect(d.rect, Rect.fromLTRB(300, 120, 420, 260));
    });

    testWidgets('line drag commits a LineDrawable with the drag endpoints',
        (tester) async {
      final host = FakeEditorHost(baseImage: baseImage);
      final c = await pumpEditorCore(tester, host);
      c.selectTool(ToolKind.line);
      await tester.pump();

      await drag(tester, const Offset(100, 400), const Offset(260, 480));

      final d = c.document.value.drawables.single as LineDrawable;
      expect(d.start, const Offset(100, 400));
      expect(d.end, const Offset(260, 480));
    });

    testWidgets('arrow drag commits an ArrowDrawable', (tester) async {
      final host = FakeEditorHost(baseImage: baseImage);
      final c = await pumpEditorCore(tester, host);
      c.selectTool(ToolKind.arrow);
      await tester.pump();

      await drag(tester, const Offset(500, 100), const Offset(640, 220));

      final d = c.document.value.drawables.single as ArrowDrawable;
      expect(d.start, const Offset(500, 100));
      expect(d.end, const Offset(640, 220));
    });

    testWidgets('pen drag commits a decimated stroke keeping the endpoints',
        (tester) async {
      final host = FakeEditorHost(baseImage: baseImage);
      final c = await pumpEditorCore(tester, host);
      c.selectTool(ToolKind.pen);
      await tester.pump();

      await drag(tester, const Offset(100, 500), const Offset(300, 560),
          via: const [Offset(150, 520), Offset(210, 510), Offset(260, 540)]);

      final d = c.document.value.drawables.single as PenDrawable;
      expect(d.points.first, const Offset(100, 500));
      expect(d.points.last, const Offset(300, 560));
      expect(d.points.length, greaterThanOrEqualTo(2));
    });

    testWidgets('a tiny drag (or slop-tap) commits nothing', (tester) async {
      final host = FakeEditorHost(baseImage: baseImage);
      final c = await pumpEditorCore(tester, host);
      c.selectTool(ToolKind.rectangle);
      await tester.pump();

      // Whether this resolves as a micro-pan (preview < 3px, discarded) or a
      // tap on empty canvas (deselect only), no drawable may be committed.
      final g = await tester.startGesture(const Offset(100, 100),
          kind: PointerDeviceKind.mouse);
      await g.moveTo(const Offset(102, 101));
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(c.document.value.drawables, isEmpty);
    });

    testWidgets('Shift mid-drag re-constrains a rectangle to a square',
        (tester) async {
      final host = FakeEditorHost(baseImage: baseImage);
      final c = await pumpEditorCore(tester, host);
      c.selectTool(ToolKind.rectangle);
      await tester.pump();

      final g = await tester.startGesture(const Offset(100, 100));
      await g.moveTo(const Offset(200, 160));
      await tester.pump();
      // Shift lands mid-drag with no pointer move: _onHardwareKey re-applies
      // the constraint at the held drag point.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      await g.up();
      await tester.pump();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);

      final d = c.document.value.drawables.single as RectangleDrawable;
      expect(d.rect, Rect.fromLTRB(100, 100, 200, 200)); // squared to max axis
    });
  });

  group('selection model (hover previews, click pins)', () {
    // Draws rect A (100,100)-(220,200) with the rectangle tool.
    Future<EditorController> pumpWithRect(
        WidgetTester tester, FakeEditorHost host) async {
      final c = await pumpEditorCore(tester, host);
      c.selectTool(ToolKind.rectangle);
      await tester.pump();
      await drag(tester, const Offset(100, 100), const Offset(220, 200));
      return c;
    }

    testWidgets('hover previews the selection WITHOUT handles; leaving clears',
        (tester) async {
      final host = FakeEditorHost(baseImage: baseImage);
      final c = await pumpWithRect(tester, host);

      final mouse = await mousePointer(tester);
      await mouse.moveTo(const Offset(150, 150));
      await tester.pump();
      expect(c.selectedIndex.value, 0);
      expect(selectionPainter(tester)!.showHandles, isFalse); // outline only

      await mouse.moveTo(const Offset(600, 500)); // empty canvas
      await tester.pump();
      expect(c.selectedIndex.value, isNull); // preview is non-sticky
      expect(selectionPainter(tester), isNull);
    });

    testWidgets('click pins: handles show and hover-away keeps the pin',
        (tester) async {
      final host = FakeEditorHost(baseImage: baseImage);
      final c = await pumpWithRect(tester, host);

      await tester.tapAt(const Offset(150, 150));
      await tester.pump();
      expect(c.selectedIndex.value, 0);
      expect(selectionPainter(tester)!.showHandles, isTrue);

      final mouse = await mousePointer(tester);
      await mouse.moveTo(const Offset(600, 500));
      await tester.pump();
      expect(c.selectedIndex.value, 0); // pinned ignores hover
      expect(selectionPainter(tester)!.showHandles, isTrue);
    });

    testWidgets('click on empty space unpins and deselects', (tester) async {
      final host = FakeEditorHost(baseImage: baseImage);
      final c = await pumpWithRect(tester, host);

      await tester.tapAt(const Offset(150, 150));
      await tester.pump();
      expect(c.selectedIndex.value, 0);

      await tester.tapAt(const Offset(600, 500));
      await tester.pump();
      expect(c.selectedIndex.value, isNull);
    });

    testWidgets('body-drag moves the shape and pins it', (tester) async {
      final host = FakeEditorHost(baseImage: baseImage);
      final c = await pumpWithRect(tester, host);

      await drag(tester, const Offset(150, 150), const Offset(180, 170));

      final d = c.document.value.drawables.single as RectangleDrawable;
      expect(d.rect, Rect.fromLTRB(130, 120, 250, 220)); // moved by (30,20)
      expect(c.selectedIndex.value, 0);
      expect(selectionPainter(tester)!.showHandles, isTrue); // drag pins
    });

    testWidgets('corner handle drag resizes both axes (handle 0 = TL)',
        (tester) async {
      final host = FakeEditorHost(baseImage: baseImage);
      final c = await pumpWithRect(tester, host);
      await tester.tapAt(const Offset(150, 150)); // pin (handles appear)
      await tester.pump();

      await drag(tester, const Offset(100, 100), const Offset(90, 85));

      final d = c.document.value.drawables.single as RectangleDrawable;
      expect(d.rect, Rect.fromLTRB(90, 85, 220, 200));
    });

    testWidgets('edge-mid handles resize a single axis (4 top, 5 right)',
        (tester) async {
      final host = FakeEditorHost(baseImage: baseImage);
      final c = await pumpWithRect(tester, host);
      await tester.tapAt(const Offset(150, 150));
      await tester.pump();

      // Handle 4 (top-mid at (160,100)): only the top edge moves.
      await drag(tester, const Offset(160, 100), const Offset(160, 80));
      var d = c.document.value.drawables.single as RectangleDrawable;
      expect(d.rect, Rect.fromLTRB(100, 80, 220, 200));

      // Handle 5 (right-mid at (220,140)): only the right edge moves.
      await drag(tester, const Offset(220, 140), const Offset(260, 140));
      d = c.document.value.drawables.single as RectangleDrawable;
      expect(d.rect, Rect.fromLTRB(100, 80, 260, 200));
    });

    testWidgets('handle hit-test scans ONLY the pinned shape (no z-steal)',
        (tester) async {
      final host = FakeEditorHost(baseImage: baseImage);
      final c = await pumpEditorCore(tester, host);
      c.selectTool(ToolKind.rectangle);
      await tester.pump();
      // A below, B above and overlapping A's bottom-right corner handle.
      await drag(tester, const Offset(100, 100), const Offset(200, 180));
      await drag(tester, const Offset(300, 260), const Offset(180, 160));

      await tester.tapAt(const Offset(110, 110)); // pin A (outside B)
      await tester.pump();
      expect(c.selectedIndex.value, 0);

      // A's BR handle (200,180) lies INSIDE B's body; the grab must still go
      // to the pinned A, and B must not move.
      await drag(tester, const Offset(200, 180), const Offset(240, 220));

      final a = c.document.value.drawables[0] as RectangleDrawable;
      final b = c.document.value.drawables[1] as RectangleDrawable;
      expect(a.rect, Rect.fromLTRB(100, 100, 240, 220));
      expect(b.rect, Rect.fromLTRB(180, 160, 300, 260));
      expect(c.selectedIndex.value, 0);
    });

    testWidgets('segment endpoint drag moves only that endpoint',
        (tester) async {
      final host = FakeEditorHost(baseImage: baseImage);
      final c = await pumpEditorCore(tester, host);
      c.selectTool(ToolKind.line);
      await tester.pump();
      await drag(tester, const Offset(400, 400), const Offset(500, 450));

      await tester.tapAt(const Offset(450, 425)); // on the segment body: pin
      await tester.pump();
      expect(c.selectedIndex.value, 0);

      await drag(tester, const Offset(500, 450), const Offset(520, 400));

      final d = c.document.value.drawables.single as LineDrawable;
      expect(d.start, const Offset(400, 400)); // anchored end untouched
      expect(d.end, const Offset(520, 400));
    });

    testWidgets('right-click deletes a same-type drawable under the cursor',
        (tester) async {
      final host = FakeEditorHost(baseImage: baseImage, rightClickExits: true);
      final c = await pumpWithRect(tester, host);

      final g = await tester.startGesture(const Offset(150, 150),
          kind: PointerDeviceKind.mouse, buttons: kSecondaryButton);
      await tester.pump();
      await g.up();
      await tester.pump();

      expect(c.document.value.drawables, isEmpty); // deleted, not exited
      expect(host.cancelCount, 0);
    });
  });

  group('cursor hide/unhide balance', () {
    testWidgets('dispose force-unhides a cursor this engine hid',
        (tester) async {
      final host = FakeEditorHost(baseImage: baseImage);
      await pumpEditorCore(tester, host);

      // Active + pointer-over-canvas starts hidden (crop shows the crosshair).
      expect(host.cursor.hiddenCalls, [true]);

      await tester.pumpWidget(Container()); // unmount -> dispose
      expect(host.cursor.hiddenCalls, [true, false]);
    });

    testWidgets('dispose does NOT spuriously unhide when never hidden',
        (tester) async {
      final host = FakeEditorHost(baseImage: baseImage, startsActive: false);
      await pumpEditorCore(tester, host);

      expect(host.cursor.hiddenCalls, isEmpty);

      await tester.pumpWidget(Container());
      expect(host.cursor.hiddenCalls, isEmpty);
    });

    testWidgets('losing the cross-display active signal unhides; regaining '
        'seeds the crosshair and re-hides', (tester) async {
      final host = FakeEditorHost(baseImage: baseImage);
      await pumpEditorCore(tester, host);
      expect(host.cursor.hiddenCalls, [true]);

      host.activeSignalNotifier.value =
          (id: host.hostId + 1, cursor: Offset.zero); // another display
      await tester.pump();
      expect(host.cursor.hiddenCalls, [true, false]);

      host.activeSignalNotifier.value =
          (id: host.hostId, cursor: const Offset(123, 45)); // back to us
      await tester.pump();
      expect(host.cursor.hiddenCalls, [true, false, true]);
    });
  });

  group('record mode (live-select)', () {
    testWidgets('tool keys are locked to the crop selector', (tester) async {
      final host = FakeEditorHost(baseImage: baseImage, liveSelect: true);
      final c = await pumpEditorCore(tester, host, recordMode: true);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyB); // blur tool key
      await tester.pump();
      expect(c.tool.value, ToolKind.crop);

      await tester.sendKeyEvent(LogicalKeyboardKey.digit1); // rectangle key
      await tester.pump();
      expect(c.tool.value, ToolKind.crop);
    });

    testWidgets('the region drag still exports through the host',
        (tester) async {
      final host = FakeEditorHost(baseImage: baseImage, liveSelect: true);
      await pumpEditorCore(tester, host, recordMode: true);

      await drag(tester, const Offset(100, 100), const Offset(340, 280));

      expect(host.exports, hasLength(1));
      expect(host.exports.single.rect, Rect.fromLTRB(100, 100, 340, 280));
    });
  });

  group('text tool', () {
    testWidgets('click places an inline editor; Enter commits a TextDrawable',
        (tester) async {
      final host = FakeEditorHost(baseImage: baseImage);
      final c = await pumpEditorCore(tester, host);
      c.selectTool(ToolKind.text);
      await tester.pump();

      await tester.tapAt(const Offset(150, 120));
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(find.byType(TextField), findsNothing);
      final d = c.document.value.drawables.single as TextDrawable;
      expect(d.text, 'hello');
      expect(d.position, const Offset(150, 120));
    });

    testWidgets('Esc cancels the entry without committing', (tester) async {
      final host = FakeEditorHost(baseImage: baseImage);
      final c = await pumpEditorCore(tester, host);
      c.selectTool(ToolKind.text);
      await tester.pump();

      await tester.tapAt(const Offset(400, 400));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'discard me');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(find.byType(TextField), findsNothing);
      expect(c.document.value.drawables, isEmpty);
      expect(host.cancelCount, 0); // Esc ended the text edit, not the session
    });

    testWidgets('clicking an existing text re-edits it in place',
        (tester) async {
      final host = FakeEditorHost(baseImage: baseImage);
      final c = await pumpEditorCore(tester, host);
      c.selectTool(ToolKind.text);
      await tester.pump();

      await tester.tapAt(const Offset(150, 120));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      await tester.tapAt(const Offset(155, 128)); // inside the text bounds
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, 'hello'); // prefilled for re-edit

      await tester.enterText(find.byType(TextField), 'hello world');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      final d = c.document.value.drawables.single as TextDrawable;
      expect(d.text, 'hello world'); // replaced in place, not appended
    });
  });
}
