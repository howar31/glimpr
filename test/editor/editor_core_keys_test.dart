import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/draw_style.dart';
import 'package:glimpr/editor/drawable.dart';
import 'package:glimpr/editor/editor_controller.dart';
import 'package:glimpr/editor/loupe_config.dart';
import 'package:glimpr/overlay/crop_hud.dart';
import 'package:glimpr/platform_gate.dart';

import '../support/fake_editor_host.dart';

/// Press [key] with optional held modifiers, releasing everything after.
Future<void> chord(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool meta = false,
  bool shift = false,
  bool control = false,
}) async {
  if (meta) await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  if (meta) await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pump();
}

LoupeReadout readout(WidgetTester tester) =>
    tester.widget<LoupeReadout>(find.byType(LoupeReadout));

void main() {
  late ui.Image baseImage;

  setUpAll(() async {
    baseImage = await makeBaseImage(800, 600);
  });

  group('tool default keys switch tools', () {
    testWidgets('each default binding selects its tool', (tester) async {
      final host = FakeEditorHost(baseImage: baseImage);
      final c = await pumpEditorCore(tester, host);

      // Stamp ('I') is deliberately absent: selecting it with no stamp image
      // opens the native file picker, which has no channel in tests.
      const cases = <(LogicalKeyboardKey, ToolKind)>[
        (LogicalKeyboardKey.digit1, ToolKind.rectangle),
        (LogicalKeyboardKey.digit2, ToolKind.ellipse),
        (LogicalKeyboardKey.digit3, ToolKind.line),
        (LogicalKeyboardKey.digit4, ToolKind.arrow),
        (LogicalKeyboardKey.digit5, ToolKind.pen),
        (LogicalKeyboardKey.keyH, ToolKind.highlighter),
        (LogicalKeyboardKey.keyT, ToolKind.text),
        (LogicalKeyboardKey.keyS, ToolKind.step),
        (LogicalKeyboardKey.keyM, ToolKind.magnify),
        (LogicalKeyboardKey.keyL, ToolKind.spotlight),
        (LogicalKeyboardKey.keyV, ToolKind.paste), // universal Select tool
        (LogicalKeyboardKey.keyB, ToolKind.blur),
        (LogicalKeyboardKey.keyP, ToolKind.pixelate),
        (LogicalKeyboardKey.keyC, ToolKind.crop),
      ];
      for (final (key, tool) in cases) {
        await tester.sendKeyEvent(key);
        await tester.pump();
        expect(c.tool.value, tool, reason: 'key $key');
      }
    });

    testWidgets('mid-drag tool keys are swallowed (no desync)',
        (tester) async {
      final host = FakeEditorHost(baseImage: baseImage);
      final c = await pumpEditorCore(tester, host);

      final g = await tester.startGesture(const Offset(100, 100));
      await g.moveTo(const Offset(250, 200));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.pump();
      expect(c.tool.value, ToolKind.crop); // still cropping

      await g.up();
      await tester.pump();
      expect(host.exports.single.rect, Rect.fromLTRB(100, 100, 250, 200));
    });
  });

  group('undo / redo dispatch', () {
    testWidgets('Cmd+Z undoes locally; Shift+Cmd+Z redoes', (tester) async {
      final host = FakeEditorHost(baseImage: baseImage);
      final c = await pumpEditorCore(tester, host);
      c.commitDrawable(const RectangleDrawable(
          Rect.fromLTWH(10, 10, 50, 50), DrawStyle()));
      await tester.pump();

      await chord(tester, LogicalKeyboardKey.keyZ, meta: true);
      expect(c.document.value.drawables, isEmpty);

      await chord(tester, LogicalKeyboardKey.keyZ, meta: true, shift: true);
      expect(c.document.value.drawables, hasLength(1));
    });

    testWidgets('Cmd+Z / Shift+Cmd+Z route through the session overrides',
        (tester) async {
      final host = FakeEditorHost(baseImage: baseImage);
      final c = await pumpEditorCore(tester, host);
      c.commitDrawable(const RectangleDrawable(
          Rect.fromLTWH(10, 10, 50, 50), DrawStyle()));
      final log = <String>[];
      c.undoOverride = () => log.add('undo');
      c.redoOverride = () => log.add('redo');
      await tester.pump();

      await chord(tester, LogicalKeyboardKey.keyZ, meta: true);
      await chord(tester, LogicalKeyboardKey.keyZ, meta: true, shift: true);

      expect(log, ['undo', 'redo']);
      // The local document was NOT touched — the router owns the op log.
      expect(c.document.value.drawables, hasLength(1));
    });
  });

  group('selection commands', () {
    testWidgets('Backspace deletes the selection; ignored with none',
        (tester) async {
      final host = FakeEditorHost(baseImage: baseImage);
      final c = await pumpEditorCore(tester, host);
      c.commitDrawable(const RectangleDrawable(
          Rect.fromLTWH(10, 10, 50, 50), DrawStyle()));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace); // no selection
      await tester.pump();
      expect(c.document.value.drawables, hasLength(1));

      c.selectedIndex.value = 0;
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(c.document.value.drawables, isEmpty);
    });

    testWidgets('Cmd+D duplicates the selection', (tester) async {
      final host = FakeEditorHost(baseImage: baseImage);
      final c = await pumpEditorCore(tester, host);
      c.commitDrawable(const RectangleDrawable(
          Rect.fromLTWH(10, 10, 50, 50), DrawStyle()));
      c.selectedIndex.value = 0;
      await tester.pump();

      await chord(tester, LogicalKeyboardKey.keyD, meta: true);

      expect(c.document.value.drawables, hasLength(2));
      expect(c.selectedIndex.value, 1); // the copy is selected
    });
  });

  group('crosshair nudge + aimed pixel', () {
    testWidgets('arrow keys nudge one physical pixel and warp the OS cursor '
        'through globalOrigin', (tester) async {
      final host = FakeEditorHost(
        baseImage: baseImage,
        cursorSeed: const Offset(100, 100),
        globalOrigin: const Offset(10, 20),
      );
      await pumpEditorCore(tester, host);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();

      // pixelScale 1.0 -> one logical point per nudge; warp is global.
      expect(host.cursor.warpCalls,
          [const Offset(111, 120), const Offset(111, 121)]);
      expect(readout(tester).x, 101);
      expect(readout(tester).y, 101);
    });

    testWidgets('the aimed pixel is round(x - 0.5) of the native position',
        (tester) async {
      final host = FakeEditorHost(
          baseImage: baseImage, cursorSeed: const Offset(400, 300));
      await pumpEditorCore(tester, host);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);

      // x.5 belongs to pixel x (stable on the pixel boundary)...
      await mouse.moveTo(const Offset(100.5, 50.5));
      await tester.pump();
      expect(readout(tester).x, 100);
      expect(readout(tester).y, 50);

      // ...and interior positions floor.
      await mouse.moveTo(const Offset(101.2, 50.9));
      await tester.pump();
      expect(readout(tester).x, 101);
      expect(readout(tester).y, 50);
    });
  });

  group('fixed keys', () {
    testWidgets("'/' (and Shift+'/' = ?) cycles the loupe info and persists "
        'each step via the host', (tester) async {
      final host = FakeEditorHost(baseImage: baseImage);
      await pumpEditorCore(tester, host);
      expect(find.byType(LoupeReadout), findsOneWidget); // coords default

      // Without element snap the `level` mode is skipped: coords -> shortcuts.
      await tester.sendKeyEvent(LogicalKeyboardKey.slash);
      await tester.pump();
      expect(find.byType(LoupeShortcutsBlock), findsOneWidget);
      expect(find.byType(LoupeReadout), findsOneWidget); // cumulative modes

      await tester.sendKeyEvent(LogicalKeyboardKey.slash);
      await tester.pump();
      expect(find.byType(LoupeReadout), findsNothing); // hidden

      // Shift+/ reports the logical key `question`, not slash+shift. Only the
      // 'web' simulation platform can synthesize an unmapped logical key (it
      // falls back to the keyLabel); the desktop key maps have no `question`.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft,
          platform: 'web');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.question,
          physicalKey: PhysicalKeyboardKey.slash, platform: 'web');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.question,
          physicalKey: PhysicalKeyboardKey.slash, platform: 'web');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft,
          platform: 'web');
      await tester.pump();
      expect(find.byType(LoupeReadout), findsOneWidget); // back to coords

      expect(host.persistedLoupeModes, [
        LoupeInfoMode.shortcuts,
        LoupeInfoMode.hidden,
        LoupeInfoMode.coords,
      ]);
    });

    testWidgets('Cmd+, opens Settings through the host', (tester) async {
      // The settings chord is platform-shaped (Ctrl+, on Windows) — pin the
      // mac chord so the expectation holds on the Windows box too.
      debugPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugPlatformOverride = null);
      final host = FakeEditorHost(baseImage: baseImage);
      await pumpEditorCore(tester, host);

      await chord(tester, LogicalKeyboardKey.comma, meta: true);

      expect(host.openSettingsCount, 1);
      expect(host.cancelCount, 0);
    });

    testWidgets('windows: Ctrl+, opens Settings through the host',
        (tester) async {
      debugPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugPlatformOverride = null);
      final host = FakeEditorHost(baseImage: baseImage);
      await pumpEditorCore(tester, host);

      await chord(tester, LogicalKeyboardKey.comma, control: true);

      expect(host.openSettingsCount, 1);
      expect(host.cancelCount, 0);
    });

    testWidgets('bare X / Q toggle the crosshair / loupe overrides',
        (tester) async {
      final host = FakeEditorHost(baseImage: baseImage);
      final c = await pumpEditorCore(tester, host);
      expect(c.crosshairOn.value, isTrue);
      expect(c.loupeOn.value, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
      await tester.pump();
      expect(c.crosshairOn.value, isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
      await tester.pump();
      expect(c.loupeOn.value, isFalse);
      expect(find.byType(LoupeReadout), findsNothing); // loupe off hides it
      expect(c.hudUserToggled, isTrue);
    });
  });

  group('eyedropper mode keys', () {
    testWidgets('Esc leaves sampling without exiting the session',
        (tester) async {
      final host = FakeEditorHost(baseImage: baseImage);
      final c = await pumpEditorCore(tester, host);
      c.startEyedropper();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(c.eyedropperActive.value, isFalse);
      expect(host.cancelCount, 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(host.cancelCount, 1); // second Esc exits
    });
  });
}
