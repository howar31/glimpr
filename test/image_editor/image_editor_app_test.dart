import 'dart:io';

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/image_editor/checkerboard.dart';
import 'package:glimpr/image_editor/image_editor_app.dart';
import 'package:glimpr/image_editor/recent_images.dart';
import 'package:glimpr/platform_gate.dart';
import 'package:glimpr/settings/settings.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

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
