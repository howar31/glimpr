import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/gif_editor/gif_editor_surface.dart';
import 'package:glimpr/image_editor/checkerboard.dart';
import 'package:glimpr/image_editor/image_editor_app.dart';
import 'package:glimpr/image_editor/recent_images.dart';
import 'package:glimpr/platform_gate.dart';
import 'package:glimpr/settings/settings.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../support/gif_fixture.dart';
import '../support/mock_channels.dart';

// The standalone Image Editor SHELL: gallery landing / open card / recent tiles
// and their right-click actions + platform-shaped chrome. The LOADED editor
// state needs a decoded image (ui image codecs never resolve inside the
// fake-async zone), so these cover the shell only — EditorCore is covered
// elsewhere.
void main() {
  const channel = MethodChannel('glimpr/imageEditor');
  late Directory tmp;
  late String path1, path2;
  // In-memory clipboard: this flutter_test build has no default handler, so an
  // unmocked Clipboard.getData/setData would hang the copy-path action.
  late Map<String, Object?> clipboard;

  setUp(() {
    // Back Settings.instance (and the recents store) with an in-memory prefs
    // platform, and silence the editor's native channel.
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    mockMethodChannel(channel);
    clipboard = {};
    mockMethodChannel(SystemChannels.platform, handler: (call) {
      if (call.method == 'Clipboard.setData') {
        clipboard['text'] = (call.arguments as Map)['text'];
      } else if (call.method == 'Clipboard.getData') {
        return {'text': clipboard['text']};
      }
      return null; // other platform methods (SystemChrome/Sound) are no-ops
    });
    tmp = Directory.systemTemp.createTempSync('glimpr_editor_app_test');
    path1 = '${tmp.path}/shot1.png';
    path2 = '${tmp.path}/shot2.png';
    // Existence is all pruneMissing checks; the bytes never need to decode.
    File(path1).writeAsBytesSync(const [0]);
    File(path2).writeAsBytesSync(const [0]);
  });

  tearDown(() {
    debugPlatformOverride = null;
    tmp.deleteSync(recursive: true);
  });

  Future<void> seedRecents() async {
    final store = RecentImagesStore(Settings.instance.store);
    await store.add(path2); // older
    await store.add(path1); // newest (prepended)
  }

  // The recent-tile context-menu rows mis-measure under the test font substitute
  // and report a benign ~15px RenderFlex overflow (the bundled font + real
  // screens do not overflow). Suppress ONLY that error around the menu pumps.
  Future<void> ignoringOverflow(Future<void> Function() body) async {
    final prior = FlutterError.onError;
    FlutterError.onError = (d) {
      if (d.exceptionAsString().contains('A RenderFlex overflowed')) return;
      prior?.call(d);
    };
    try {
      await body();
    } finally {
      FlutterError.onError = prior;
    }
  }

  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const ImageEditorApp());
    await tester.pumpAndSettle();
  }

  testWidgets('Checkerboard paints in light + dark without throwing',
      (tester) async {
    for (final dark in [true, false]) {
      await tester.pumpWidget(MaterialApp(home: Checkerboard(dark: dark)));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('empty recents -> the open-card landing', (tester) async {
    await pumpApp(tester);
    expect(find.text('Open an image to edit'), findsOneWidget);
    expect(find.text('Open Image…'), findsOneWidget);
    // No gallery tiles.
    expect(find.text('Recent'), findsNothing);
  });

  /// Drives a real GIF decode: the open chain does IO + engine decode, so
  /// interleave real-async turns with pumps until [finder] resolves.
  Future<void> pumpUntilFound(WidgetTester tester, Finder finder) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
    expect(finder, findsOneWidget);
  }

  String writeGif(String name) {
    final path = '${tmp.path}/$name';
    File(path).writeAsBytesSync(twoFrameGifFixture());
    return path;
  }

  testWidgets('a .gif loaded here mounts the GIF surface, not a relay',
      (tester) async {
    // macOS-shaped: the title-bar GIF chip / meta chord.
    debugPlatformOverride = TargetPlatform.macOS;
    final calls = mockMethodChannel(channel);
    final gifPath = writeGif('anim.gif');
    await pumpApp(tester);
    unawaited(pushFromNative(channel, 'loadPath', gifPath));
    await pumpUntilFound(tester, find.byType(GifEditorSurface));
    expect(find.byKey(const Key('gif-editor-canvas')), findsOneWidget);
    expect(calls.where((c) => c.method == 'openGifEditor'), isEmpty);
    expect(find.text('Open an image to edit'), findsNothing);
    // The title bar marks the document kind.
    expect(find.text('GIF'), findsOneWidget);
  }, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('Home from a GIF returns to the landing', (tester) async {
    // macOS-shaped: the title-bar GIF chip / meta chord.
    debugPlatformOverride = TargetPlatform.macOS;
    mockMethodChannel(channel);
    final gifPath = writeGif('anim.gif');
    await pumpApp(tester);
    unawaited(pushFromNative(channel, 'loadPath', gifPath));
    await pumpUntilFound(tester, find.byType(GifEditorSurface));
    await tester.tap(find.byTooltip('Home'));
    // The title bar's double-tap recognizer holds the arena; the single tap
    // fires only after the double-tap window lapses.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.byType(GifEditorSurface), findsNothing);
    // Temp-dir files are not recorded as recents, so the open card shows.
    expect(find.text('Open Image…'), findsOneWidget);
  }, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('a dirty GIF confirms on requestClose; cancel keeps it',
      (tester) async {
    final calls = mockMethodChannel(channel);
    final gifPath = writeGif('anim.gif');
    await pumpApp(tester);
    unawaited(pushFromNative(channel, 'loadPath', gifPath));
    await pumpUntilFound(tester, find.byType(GifEditorSurface));
    // Select frame 0 and delete it: the document is now dirty.
    await tester.tap(find.byKey(const Key('gif-frame-0')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('gif-op-delete')));
    await tester.pump();
    unawaited(pushFromNative(channel, 'requestClose'));
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(GifEditorSurface), findsOneWidget);
    expect(calls.where((c) => c.method == 'hideEditor'), isEmpty);
    // Confirming hides the window and drops the document.
    unawaited(pushFromNative(channel, 'requestClose'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'hideEditor'), hasLength(1));
    expect(find.byType(GifEditorSurface), findsNothing);
  }, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('loadClipboard with no image but a copied .gif file loads it',
      (tester) async {
    mockMethodChannel(channel);
    final gifPath = writeGif('clip.gif');
    mockMethodChannel(const MethodChannel('glimpr/clipboard'),
        handler: (call) {
      if (call.method == 'readFilePath') return gifPath;
      return null; // readImage: no bitmap on the clipboard
    });
    await pumpApp(tester);
    unawaited(pushFromNative(channel, 'loadClipboard'));
    await pumpUntilFound(tester, find.byType(GifEditorSurface));
  }, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('a recent .gif tile carries the GIF badge', (tester) async {
    mockMethodChannel(channel);
    final store = RecentImagesStore(Settings.instance.store);
    final gifPath = '${tmp.path}/anim.gif';
    File(gifPath).writeAsBytesSync(const [0]); // existence only
    await store.add(gifPath);
    await store.add(path1);
    await pumpApp(tester);
    expect(find.text('anim.gif'), findsOneWidget);
    expect(find.text('shot1.png'), findsOneWidget);
    expect(find.text('GIF'), findsOneWidget); // one badge, on the gif tile only
  });

  testWidgets('cmd-O opens the file picker from the landing', (tester) async {
    // macOS-shaped: the title-bar GIF chip / meta chord.
    debugPlatformOverride = TargetPlatform.macOS;
    final calls = mockMethodChannel(channel);
    await pumpApp(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyO);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(calls.map((c) => c.method), contains('openPanel'));
  });

  testWidgets('seeded recents -> the gallery grid + open bar', (tester) async {
    await seedRecents();
    await pumpApp(tester);
    expect(find.text('Recent'), findsOneWidget);
    expect(find.text('Open Image…'), findsOneWidget); // the slim open bar
    // Both recents appear as tile captions (basenames).
    expect(find.text('shot1.png'), findsOneWidget);
    expect(find.text('shot2.png'), findsOneWidget);
  });

  testWidgets('tile right-click -> Copy Path copies the path to the clipboard',
      (tester) async {
    await seedRecents();
    await pumpApp(tester);
    // Pump fixed frames (not pumpAndSettle: the open menu keeps a frame
    // scheduled) and suppress the menu's benign test-font overflow.
    await ignoringOverflow(() async {
      await tester.tap(find.text('shot1.png'), buttons: kSecondaryButton);
      await tester.pump();
      await tester.pump();
      // The context menu offers Edit + Copy Path (among others).
      expect(find.text('Edit'), findsOneWidget);
      expect(find.text('Copy Path'), findsOneWidget);
      await tester.tap(find.text('Copy Path'));
      await tester.pump();
      await tester.pump();
    });
    // The copy-path action wrote the path to the (mocked) clipboard.
    expect(clipboard['text'], path1);

    // Copy-path toasts; drain its dismiss timers so none leak past the test.
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('tile right-click -> Remove drops it from the grid + store',
      (tester) async {
    await seedRecents();
    await pumpApp(tester);
    expect(find.text('shot1.png'), findsOneWidget);

    await ignoringOverflow(() async {
      await tester.tap(find.text('shot1.png'), buttons: kSecondaryButton);
      await tester.pump();
      await tester.pump();
      await tester.tap(find.text('Remove from Recent'));
      await tester.pump();
      await tester.pump();
    });

    // Gone from the grid AND from the persisted recents list.
    expect(find.text('shot1.png'), findsNothing);
    expect(find.text('shot2.png'), findsOneWidget);
    final recents = await RecentImagesStore(Settings.instance.store).load();
    expect(recents, isNot(contains(path1)));
    expect(recents, contains(path2));
  });

  testWidgets('macOS renders the Flutter title bar', (tester) async {
    debugPlatformOverride = TargetPlatform.macOS;
    await seedRecents();
    await pumpApp(tester);
    // The frameless macOS window draws its own "Image Editor" title bar.
    expect(find.text('Image Editor'), findsOneWidget);
  });

  testWidgets('Windows omits the Flutter title bar (uses the OS caption)',
      (tester) async {
    debugPlatformOverride = TargetPlatform.windows;
    final calls = mockMethodChannel(channel);
    await seedRecents();
    await pumpApp(tester);
    // No Flutter title bar on Windows.
    expect(find.text('Image Editor'), findsNothing);
    // The localized title is pushed to the native OS caption instead.
    expect(calls.any((c) => c.method == 'setWindowTitle'), isTrue);
  });
}
