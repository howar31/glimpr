import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/gestures.dart';
import 'package:glimpr/gif_editor/encode/gif_writer.dart';
import 'package:glimpr/gif_editor/frame_store.dart';
import 'package:glimpr/gif_editor/gif_editor_app.dart';
import 'package:glimpr/gif_editor/gif_editor_controller.dart';
import 'package:glimpr/gif_editor/gif_import.dart';
import 'package:glimpr/l10n/gen/app_localizations.dart';
import 'package:glimpr/platform_gate.dart';

import '../support/gif_fixture.dart';
import '../support/mock_channels.dart';

const _channel = MethodChannel('glimpr/gifEditor');

AppLocalizations get _en => lookupAppLocalizations(const Locale('en'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // These tests exercise the macOS (channel) picker branch on BOTH suite
  // hosts; the Windows branch goes through the file_selector plugin, which
  // has no implementation in the test environment.
  setUp(() => debugPlatformOverride = TargetPlatform.macOS);
  tearDown(() => debugPlatformOverride = null);

  testWidgets('landing shows the open card', (tester) async {
    mockMethodChannel(_channel);
    await tester.pumpWidget(const GifEditorApp());
    await tester.pump();
    expect(find.text(_en.gifEditorOpenGif), findsOneWidget);
    expect(find.text(_en.gifEditorOpenGifButton), findsOneWidget);
  });

  testWidgets('cancelled open panel keeps the landing', (tester) async {
    final calls = mockMethodChannel(_channel); // every call answers null
    await tester.pumpWidget(const GifEditorApp());
    await tester.pump();
    await tester.tap(find.text(_en.gifEditorOpenGifButton));
    await tester.pump();
    expect(calls.map((c) => c.method), contains('openPanel'));
    expect(find.text(_en.gifEditorOpenGifButton), findsOneWidget);
  });

  testWidgets('opening a GIF leaves the landing and shows the editor',
      (tester) async {
    // Async IO awaited directly in the test body parks under the fake zone
    // (nothing drains it) — the setup must run inside runAsync.
    final dir = (await tester
        .runAsync(() => Directory.systemTemp.createTemp('gifed_app')))!;
    final gifPath = '${dir.path}/in.gif';
    File(gifPath).writeAsBytesSync(twoFrameGifFixture());
    addTearDown(() => dir.deleteSync(recursive: true));

    mockMethodChannel(_channel, handler: (call) {
      if (call.method == 'openPanel') return gifPath;
      return null;
    });
    await tester.pumpWidget(const GifEditorApp());
    await tester.pump();
    await tester.tap(find.text(_en.gifEditorOpenGifButton));
    await tester.pump();
    // The open flow does real IO + engine decode; interleave real-async
    // turns with pumps until the editor mounts (the suite's pumpUntil
    // idiom — a single runAsync delay is not enough because the chain
    // needs frames pumped between its real-async segments).
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (find
            .byKey(const Key('gif-editor-canvas'))
            .evaluate()
            .isEmpty &&
        DateTime.now().isBefore(deadline)) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
    expect(find.text(_en.gifEditorOpenGifButton), findsNothing);
    expect(find.byKey(const Key('gif-editor-canvas')), findsOneWidget);
  }, timeout: const Timeout(Duration(seconds: 60)));

  Future<GifEditorController> preloaded(WidgetTester tester) async {
    final c = GifEditorController();
    addTearDown(c.dispose);
    // The heavy open path (IO + engine decode) runs under runAsync; the
    // widget then mounts against a ready document.
    await tester.runAsync(() => c.openBytes(twoFrameGifFixture()));
    return c;
  }

  testWidgets('filmstrip tiles, stats and tap-to-seek', (tester) async {
    mockMethodChannel(_channel);
    final c = await preloaded(tester);
    await tester.pumpWidget(GifEditorApp(controller: c));
    await tester.pump();
    expect(find.byKey(const Key('gif-frame-0')), findsOneWidget);
    expect(find.byKey(const Key('gif-frame-1')), findsOneWidget);
    expect(
        find.textContaining(_en.gifEditorStatsFrames(2)), findsOneWidget);
    await tester.tap(find.byKey(const Key('gif-frame-1')));
    await tester.pump();
    expect(c.current, 1);
  });

  testWidgets('export writes a decodable GIF and toasts success',
      (tester) async {
    final dir = (await tester
        .runAsync(() => Directory.systemTemp.createTemp('gifed_export_ui')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final outPath = '${dir.path}/out.gif';

    final calls = mockMethodChannel(_channel, handler: (call) {
      if (call.method == 'savePanel') return outPath;
      return null;
    });
    final c = await preloaded(tester);
    await tester.pumpWidget(GifEditorApp(controller: c));
    await tester.pump();
    await tester.tap(find.text(_en.gifEditorExportButton));
    await tester.pump();
    // Encode runs on a real isolate; drain until the success toast shows.
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (find.text(_en.gifEditorExportDone).evaluate().isEmpty &&
        DateTime.now().isBefore(deadline)) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
    expect(find.text(_en.gifEditorExportDone), findsOneWidget);
    // The tray processing pulse bracketed the export.
    final processing =
        calls.where((call) => call.method == 'setProcessing').toList();
    expect(processing.length, 2);
    expect((processing.first.arguments as Map)['active'], isTrue);
    expect((processing.last.arguments as Map)['active'], isFalse);
    // The written file is a real 2-frame GIF.
    final reread = await tester.runAsync(() async => importGif(
        Uint8List.fromList(File(outPath).readAsBytesSync()),
        FrameStore(await Directory.systemTemp.createTemp('reread'))));
    expect(reread!.frameCount, 2);
  }, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('cancelled save panel exports nothing', (tester) async {
    final calls = mockMethodChannel(_channel); // savePanel answers null
    final c = await preloaded(tester);
    await tester.pumpWidget(GifEditorApp(controller: c));
    await tester.pump();
    await tester.tap(find.text(_en.gifEditorExportButton));
    await tester.pump();
    expect(calls.map((call) => call.method), contains('savePanel'));
    expect(calls.map((call) => call.method),
        isNot(contains('setProcessing')));
    expect(find.text(_en.gifEditorExportDone), findsNothing);
  });

  testWidgets('play toggle advances frames on their own delays',
      (tester) async {
    mockMethodChannel(_channel);
    final c = await preloaded(tester);
    await tester.pumpWidget(GifEditorApp(controller: c));
    await tester.pump();
    await tester.tap(find.byKey(const Key('gif-play-toggle')));
    await tester.pump();
    expect(c.playing, isTrue);
    // Frame 0 holds for 200ms (fixture), then frame 1.
    await tester.pump(const Duration(milliseconds: 210));
    expect(c.current, 1);
    // Frame 1 holds for 400ms, then wraps.
    await tester.pump(const Duration(milliseconds: 410));
    expect(c.current, 0);
    await tester.tap(find.byKey(const Key('gif-play-toggle')));
    await tester.pump();
    expect(c.playing, isFalse);
  });

  testWidgets('home returns to the landing', (tester) async {
    mockMethodChannel(_channel);
    final c = await preloaded(tester);
    await tester.pumpWidget(GifEditorApp(controller: c));
    await tester.pump();
    expect(find.byKey(const Key('gif-home')), findsOneWidget);
    await tester.tap(find.byKey(const Key('gif-home')));
    // The title bar's double-tap recognizer holds the arena; the single tap
    // fires only after the double-tap window lapses.
    await tester.pump(const Duration(milliseconds: 400));
    expect(c.doc, isNull);
    expect(find.text(_en.gifEditorOpenGifButton), findsOneWidget);
    expect(find.byKey(const Key('gif-home')), findsNothing);
  });

  testWidgets('cmd-O opens the file picker from anywhere', (tester) async {
    final calls = mockMethodChannel(_channel);
    final c = await preloaded(tester);
    await tester.pumpWidget(GifEditorApp(controller: c));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyO);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(calls.map((call) => call.method), contains('openPanel'));
  });

  testWidgets('export options popover opens, edits state and dismisses',
      (tester) async {
    mockMethodChannel(_channel);
    final c = await preloaded(tester);
    await tester.pumpWidget(GifEditorApp(controller: c));
    await tester.pump();
    expect(find.byKey(const Key('gif-options-popover')), findsNothing);
    await tester.tap(find.byKey(const Key('gif-export-options')));
    await tester.pump();
    expect(find.byKey(const Key('gif-options-popover')), findsOneWidget);
    expect(find.text(_en.gifEditorPalette), findsOneWidget);
    // Palette strategy segment.
    await tester.tap(find.text(_en.gifEditorPalettePerFrame));
    await tester.pump();
    // Dither toggle.
    await tester.tap(find.byKey(const Key('gif-opt-dither')));
    await tester.pump();
    // Finite loop reveals the count field.
    expect(
        find.byKey(const Key('gif-opt-loop-count-field')), findsNothing);
    await tester.tap(find.text(_en.gifEditorLoopCount));
    await tester.pump();
    expect(
        find.byKey(const Key('gif-opt-loop-count-field')), findsOneWidget);
    await tester.enterText(
        find.byKey(const Key('gif-opt-loop-count-field')), '4');
    await tester.pump();
    // Outside tap dismisses.
    await tester.tapAt(const Offset(10, 100));
    await tester.pump();
    expect(find.byKey(const Key('gif-options-popover')), findsNothing);
    // State survived the dismiss: reopen shows the field again.
    await tester.tap(find.byKey(const Key('gif-export-options')));
    await tester.pump();
    expect(
        find.byKey(const Key('gif-opt-loop-count-field')), findsOneWidget);
  });

  testWidgets('export honors the loop count chosen in the options',
      (tester) async {
    final dir = (await tester
        .runAsync(() => Directory.systemTemp.createTemp('gifed_optexp')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final outPath = '${dir.path}/out.gif';
    mockMethodChannel(_channel, handler: (call) {
      if (call.method == 'savePanel') return outPath;
      return null;
    });
    final c = await preloaded(tester);
    await tester.pumpWidget(GifEditorApp(controller: c));
    await tester.pump();
    // Choose a finite loop of 4 (fixture is loop-forever).
    await tester.tap(find.byKey(const Key('gif-export-options')));
    await tester.pump();
    await tester.tap(find.text(_en.gifEditorLoopCount));
    await tester.pump();
    await tester.enterText(
        find.byKey(const Key('gif-opt-loop-count-field')), '4');
    await tester.tapAt(const Offset(10, 100));
    await tester.pump();
    await tester.tap(find.text(_en.gifEditorExportButton));
    await tester.pump();
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (find.text(_en.gifEditorExportDone).evaluate().isEmpty &&
        DateTime.now().isBefore(deadline)) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
    expect(find.text(_en.gifEditorExportDone), findsOneWidget);
    final reread = await tester.runAsync(() async => importGif(
        Uint8List.fromList(File(outPath).readAsBytesSync()),
        FrameStore(await Directory.systemTemp.createTemp('reread_opt'))));
    expect(reread!.loopCount, 4);
  }, timeout: const Timeout(Duration(seconds: 60)));

  Future<GifEditorController> preloadedN(
      WidgetTester tester, List<int> colors, List<int> delaysMs) async {
    final c = GifEditorController();
    addTearDown(c.dispose);
    await tester.runAsync(() =>
        c.openBytes(solidFramesGif(colors: colors, delays: delaysMs)));
    return c;
  }

  testWidgets('filmstrip clicks select (plain, shift-range, mod-toggle)',
      (tester) async {
    mockMethodChannel(_channel);
    final c =
        await preloadedN(tester, [0, 1, 2, 3], [100, 100, 100, 100]);
    await tester.pumpWidget(GifEditorApp(controller: c));
    await tester.pump();
    await tester.tap(find.byKey(const Key('gif-frame-1')));
    await tester.pump();
    expect(c.selection, {1});
    expect(c.current, 1);
    // Shift-click extends the range; the playhead stays.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.byKey(const Key('gif-frame-3')));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(c.selection, {1, 2, 3});
    expect(c.current, 1);
    // Cmd-click toggles one member off.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.tap(find.byKey(const Key('gif-frame-2')));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(c.selection, {1, 3});
  });

  testWidgets('toolbar delete and undo round-trip', (tester) async {
    mockMethodChannel(_channel);
    final c = await preloadedN(tester, [0, 1, 2], [100, 150, 200]);
    await tester.pumpWidget(GifEditorApp(controller: c));
    await tester.pump();
    await tester.tap(find.byKey(const Key('gif-frame-1')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('gif-op-delete')));
    await tester.pump();
    expect(c.doc!.frameCount, 2);
    await tester.tap(find.byKey(const Key('gif-op-undo')));
    await tester.pump();
    expect(c.doc!.frameCount, 3);
    expect(c.doc!.frames[1].delayMs, 150);
  });

  testWidgets('delay panel applies the chosen mode', (tester) async {
    mockMethodChannel(_channel);
    final c = await preloadedN(tester, [0, 1], [100, 150]);
    await tester.pumpWidget(GifEditorApp(controller: c));
    await tester.pump();
    await tester.tap(find.byKey(const Key('gif-op-delay')));
    await tester.pump();
    expect(find.byKey(const Key('gif-delay-panel')), findsOneWidget);
    await tester.enterText(
        find.byKey(const Key('gif-delay-field')), '500');
    await tester.tap(find.byKey(const Key('gif-delay-apply')));
    await tester.pump();
    // No selection: applies to every frame; the panel closes.
    expect([for (final f in c.doc!.frames) f.delayMs], [500, 500]);
    expect(find.byKey(const Key('gif-delay-panel')), findsNothing);
  });

  testWidgets('reduce panel keeps the first of every n', (tester) async {
    mockMethodChannel(_channel);
    final c =
        await preloadedN(tester, [0, 1, 2, 3], [100, 100, 100, 100]);
    await tester.pumpWidget(GifEditorApp(controller: c));
    await tester.pump();
    await tester.tap(find.byKey(const Key('gif-op-reduce')));
    await tester.pump();
    expect(find.byKey(const Key('gif-reduce-panel')), findsOneWidget);
    await tester.tap(find.byKey(const Key('gif-reduce-apply')));
    await tester.pump();
    expect(c.doc!.frameCount, 2); // default n = 2
    expect(c.doc!.frames[0].delayMs, 200);
  });

  testWidgets('undo and select-all hotkeys reach the controller',
      (tester) async {
    mockMethodChannel(_channel);
    final c = await preloadedN(tester, [0, 1, 2], [100, 100, 100]);
    await tester.pumpWidget(GifEditorApp(controller: c));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(c.selection, {0, 1, 2});
    // Delete two of them (keep one), then undo via the hotkey.
    await tester.tap(find.byKey(const Key('gif-frame-1')));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.byKey(const Key('gif-frame-2')));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    expect(c.doc!.frameCount, 1);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(c.doc!.frameCount, 3);
  });

  testWidgets('plain vertical wheel scrolls the filmstrip', (tester) async {
    mockMethodChannel(_channel);
    // 30 frames so the strip overflows the 800px test surface.
    final c = GifEditorController();
    addTearDown(c.dispose);
    await tester.runAsync(() async {
      final frames = List.generate(
          30,
          (i) => FrameSpec(
              Uint8List.fromList([255, 0, 0, 255]), 100));
      await c.openBytes(encodeGifFrames(
          frames: frames, width: 1, height: 1, loopCount: 0));
    });
    await tester.pumpWidget(GifEditorApp(controller: c));
    await tester.pump();
    expect(c.doc, isNotNull,
        reason: 'the 30-frame document should have opened');
    expect(find.byKey(const Key('gif-editor-canvas')), findsOneWidget);
    // skipOffstage:false — after scrolling, tile 0 leaves the painted
    // viewport but stays laid out in the sliver cache.
    final before = tester.getTopLeft(
        find.byKey(const Key('gif-frame-0'), skipOffstage: false));
    final strip = tester.getCenter(find.byKey(const Key('gif-frame-0')));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    pointer.hover(strip);
    await tester.sendEventToBinding(
        pointer.scroll(const Offset(0, 120))); // plain vertical wheel
    await tester.pump();
    final after = tester.getTopLeft(
        find.byKey(const Key('gif-frame-0'), skipOffstage: false));
    expect(after.dx, lessThan(before.dx)); // strip moved right
  });
}
