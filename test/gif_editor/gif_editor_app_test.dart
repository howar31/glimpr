import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
