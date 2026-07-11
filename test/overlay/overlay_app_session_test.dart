
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:glimpr/overlay/editor_canvas.dart';
import 'package:glimpr/overlay/overlay_app.dart';
import 'package:glimpr/settings/settings_mask.dart';
import '../support/mock_channels.dart';

const _overlay = MethodChannel('glimpr/overlay');
const _capture = MethodChannel('glimpr/capture');

// A screenshot onCaptureReady payload with a real (decodable) BGRA buffer.
Map<String, Object?> captureArgs({bool liveSelect = false, int id = 1}) {
  // Match the default test surface so the floating toolbar has room to lay out.
  const w = 800, h = 600;
  return {
    'display': <String, Object?>{
      'displayId': id,
      'rawBytes': Uint8List(w * h * 4),
      'pixelWidth': w,
      'pixelHeight': h,
      'rowBytes': w * 4,
      'left': 0.0,
      'top': 0.0,
      'width': w.toDouble(),
      'height': h.toDouble(),
      'scaleFactor': 1.0,
      'isCursorDisplay': true,
    },
    'pinOnly': false,
    'liveSelect': liveSelect,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    // Keep the HUD static so no marching-ants Timer.periodic outlives the test.
    final prefs = SharedPreferencesAsync();
    await prefs.setBool('hud_marching_ants', false);
    await prefs.setBool('hud_crosshair', false);
    await prefs.setBool('hud_loupe', false);
    // Swallow the fire-and-forget calls the overlay makes on glimpr/capture
    // (overlayReady, perfMark, stopLoupeFeed, dismissOverlay, ...).
    mockMethodChannel(_capture);
  });

  tearDown(() => _overlay.setMethodCallHandler(null));

  // Drive a native onCaptureReady and let its async image decode + settings
  // prefetch settle, then rebuild.
  Future<void> deliverCapture(WidgetTester tester,
      Map<String, Object?> args) async {
    await tester.runAsync(() async {
      await pushFromNative(_overlay, 'onCaptureReady', args);
      await Future<void>.delayed(const Duration(milliseconds: 60));
    });
    await tester.pump();
  }

  // Wall-clock poll between real-async waits and pumps. A fixed settle delay
  // is not enough on slow CI runners (a capture's real image decode can
  // outlast it); same class as the record relay tests' pumpUntil.
  Future<void> pumpUntil(WidgetTester tester, bool Function() cond,
      {Duration timeout = const Duration(seconds: 10)}) async {
    final deadline = DateTime.now().add(timeout);
    while (!cond() && DateTime.now().isBefore(deadline)) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
  }

  testWidgets('idle overlay shows nothing and mounts no canvas', (tester) async {
    await tester.pumpWidget(const OverlayApp());
    await tester.pump();
    expect(find.byType(EditorCanvas), findsNothing);
  });

  testWidgets('a screenshot capture mounts the session canvas', (tester) async {
    await tester.pumpWidget(const OverlayApp());
    await tester.pump();
    await deliverCapture(tester, captureArgs());

    final canvas = find.byType(EditorCanvas);
    expect(canvas, findsOneWidget);
    // A screenshot session: interactive (not the presentation-only RS case).
    final w = tester.widget<EditorCanvas>(canvas);
    expect(w.recordMode, isFalse);
    expect(w.presentationOnly, isFalse);
  });

  testWidgets('a Settings detour masks the frozen session, resume clears it',
      (tester) async {
    await tester.pumpWidget(const OverlayApp());
    await tester.pump();
    await deliverCapture(tester, captureArgs());

    await pushFromNative(_overlay, 'onSettingsOpen');
    await tester.pump();
    expect(find.byType(SettingsMask), findsOneWidget);

    await tester.runAsync(() async {
      await pushFromNative(_overlay, 'onResume');
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    expect(find.byType(SettingsMask), findsNothing);
  });

  testWidgets('record-select arms an additive picker; the hotkey cancels it',
      (tester) async {
    await tester.pumpWidget(const OverlayApp());
    await tester.pump();
    await deliverCapture(tester, captureArgs(liveSelect: true));

    // The record-select picker is a recordMode canvas over the live screen.
    final canvas = find.byType(EditorCanvas);
    expect(canvas, findsOneWidget);
    expect(tester.widget<EditorCanvas>(canvas).recordMode, isTrue);

    // A second record hotkey while the picker is foreground cancels it.
    await tester.runAsync(() async {
      await pushFromNative(_overlay, 'onRecordSelectHotkey');
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump();
    expect(find.byType(EditorCanvas), findsNothing);
  });

  testWidgets('a screenshot while record-select is up suspends the picker',
      (tester) async {
    await tester.pumpWidget(const OverlayApp());
    await tester.pump();
    await deliverCapture(tester, captureArgs(liveSelect: true));
    expect(tester.widget<EditorCanvas>(find.byType(EditorCanvas)).recordMode,
        isTrue);

    // A real capture arrives: RS suspends, a normal session canvas takes over.
    await deliverCapture(tester, captureArgs());
    await pumpUntil(tester, () {
      final canvases = find.byType(EditorCanvas);
      if (canvases.evaluate().length != 1) return false;
      return !tester.widget<EditorCanvas>(canvases).recordMode;
    });
    final canvas = find.byType(EditorCanvas);
    expect(canvas, findsOneWidget);
    expect(tester.widget<EditorCanvas>(canvas).recordMode, isFalse);
  });
}
