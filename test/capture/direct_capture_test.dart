import 'dart:typed_data';
import 'dart:ui' show Rect;
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/capture/capture_kind.dart';
import 'package:glimpr/capture/captured_display.dart';
import 'package:glimpr/capture/direct_capture.dart';
import 'package:glimpr/capture/last_region.dart';
import 'package:glimpr/output/deliver.dart';
import 'package:glimpr/settings/settings.dart';
import 'package:glimpr/settings/settings_store.dart';

class _FakeStore implements SettingsStore {
  final Map<String, Object> _m = {};
  @override
  Future<String?> getString(String k) async => _m[k] as String?;
  @override
  Future<void> setString(String k, String v) async => _m[k] = v;
  @override
  Future<bool?> getBool(String k) async => _m[k] as bool?;
  @override
  Future<void> setBool(String k, bool v) async => _m[k] = v;
  @override
  Future<int?> getInt(String k) async => _m[k] as int?;
  @override
  Future<void> setInt(String k, int v) async => _m[k] = v;
  @override
  Future<void> remove(String k) async => _m.remove(k);
}

CapturedDisplay _disp(int id, {bool cursor = false, double w = 1920, double h = 1080}) =>
    CapturedDisplay(
      displayId: id,
      pngBytes: Uint8List(0),
      left: 0,
      top: 0,
      width: w,
      height: h,
      scaleFactor: 2,
      isCursorDisplay: cursor,
    );

void main() {
  group('resolveScreenTarget', () {
    test('picks the cursor display, labelled DISPLAY', () {
      final t = resolveScreenTarget([_disp(1), _disp(2, cursor: true)]);
      expect(t!.display.displayId, 2);
      expect(t.kind, CaptureKind.display);
      expect(t.selectionLogical, isNull);
      expect(t.windowTitle, 'DISPLAY');
      expect(t.appName, 'DISPLAY');
    });
    test('falls back to the first display when none is the cursor display', () {
      final t = resolveScreenTarget([_disp(5), _disp(6)]);
      expect(t!.display.displayId, 5);
    });
    test('returns null when there are no frames', () {
      expect(resolveScreenTarget(const []), isNull);
    });
  });

  group('resolveWindowTarget', () {
    test('targets the focused window rect on its display', () {
      final t = resolveWindowTarget([_disp(1, cursor: true), _disp(2)],
          const FocusedWindowInfo(
              displayId: 2,
              rect: Rect.fromLTWH(30, 40, 500, 360),
              title: 'Editor',
              app: 'Code'));
      expect(t!.display.displayId, 2);
      expect(t.kind, CaptureKind.focusedWindow);
      expect(t.selectionLogical, const Rect.fromLTWH(30, 40, 500, 360));
      expect(t.windowTitle, 'Editor');
      expect(t.appName, 'Code');
    });
    test('no focused window -> falls back to the cursor display, whole screen', () {
      final t = resolveWindowTarget([_disp(1), _disp(2, cursor: true)], null);
      expect(t!.display.displayId, 2);
      expect(t.kind, CaptureKind.display); // fallback is a plain display capture
      expect(t.selectionLogical, isNull);
    });
    test('focused window on an uncaptured display -> falls back to screen', () {
      final t = resolveWindowTarget([_disp(1, cursor: true)],
          const FocusedWindowInfo(
              displayId: 99,
              rect: Rect.fromLTWH(0, 0, 10, 10),
              title: '',
              app: ''));
      expect(t!.display.displayId, 1);
      expect(t.selectionLogical, isNull);
    });
  });

  group('resolveLastRegionTarget', () {
    test('crops the stored rect on the stored display, labelled LAST', () {
      final t = resolveLastRegionTarget([_disp(3), _disp(4)],
          const LastRegion(displayId: 4, rect: Rect.fromLTWH(1, 2, 300, 200)));
      expect(t!.display.displayId, 4);
      expect(t.kind, CaptureKind.lastRegion);
      expect(t.selectionLogical, const Rect.fromLTWH(1, 2, 300, 200));
      expect(t.windowTitle, 'LAST');
      expect(t.appName, 'LAST');
    });
    test('null region -> null (no-op)', () {
      expect(resolveLastRegionTarget([_disp(3)], null), isNull);
    });
    test('stored display gone -> null (no-op)', () {
      final t = resolveLastRegionTarget([_disp(3)],
          const LastRegion(displayId: 99, rect: Rect.fromLTWH(0, 0, 5, 5)));
      expect(t, isNull);
    });
  });

  group('DirectCapture orchestrator', () {
    late _FakeStore store;
    late LastRegionStore regionStore;
    late List<CaptureTarget> delivered;
    late int shutters;
    late int completes;
    late List<String> errors;

    DirectCapture build({
      required List<CapturedDisplay> frames,
      FocusedWindowInfo? window,
    }) {
      store = _FakeStore();
      regionStore = LastRegionStore(store);
      delivered = [];
      shutters = 0;
      completes = 0;
      errors = [];
      return DirectCapture(
        captureFrames: ({bool showsCursor = false}) async => frames,
        focusedWindow: () async => window,
        settings: Settings(store),
        regionStore: regionStore,
        deliver: (t, cap) async {
          delivered.add(t);
          return const DeliveryResult(
              savedPath: '/tmp/x.png', copiedToClipboard: true, soundPlayed: false);
        },
        shutter: () => shutters++,
        complete: () => completes++,
        showError: (m) => errors.add(m),
      );
    }

    test('screen(): delivers the cursor display, sounds, records full region',
        () async {
      final dc = build(frames: [_disp(1), _disp(2, cursor: true)]);
      await dc.screen();
      expect(delivered.single.display.displayId, 2);
      expect(delivered.single.selectionLogical, isNull);
      expect(shutters, 1);
      expect(completes, 1);
      final saved = await regionStore.load();
      expect(saved!.displayId, 2);
      expect(saved.rect, const Rect.fromLTWH(0, 0, 1920, 1080));
    });

    test('window(): delivers the focused window rect + records it', () async {
      final dc = build(
        frames: [_disp(1, cursor: true), _disp(2)],
        window: const FocusedWindowInfo(
            displayId: 2,
            rect: Rect.fromLTWH(5, 6, 100, 80),
            title: 'W',
            app: 'A'),
      );
      await dc.window();
      expect(delivered.single.display.displayId, 2);
      expect(delivered.single.selectionLogical, const Rect.fromLTWH(5, 6, 100, 80));
      final saved = await regionStore.load();
      expect(saved!.rect, const Rect.fromLTWH(5, 6, 100, 80));
    });

    test('window(): uses the per-window image when a windowId is present',
        () async {
      final s = _FakeStore();
      WindowImage? deliveredWi;
      var completes = 0;
      final dc = DirectCapture(
        captureFrames: ({bool showsCursor = false}) async =>
            [_disp(1, cursor: true)],
        focusedWindow: () async => const FocusedWindowInfo(
            displayId: 1,
            rect: Rect.fromLTWH(5, 6, 100, 80),
            title: 'W',
            app: 'App',
            windowId: 99),
        captureWindowImage: (id, {bool showsCursor = false}) async {
          expect(id, 99);
          return WindowImage(
              pngBytes: Uint8List(0), width: 200, height: 160, scale: 2);
        },
        deliverWindow: (wi, cap, info) async {
          deliveredWi = wi;
          return const DeliveryResult(
              savedPath: '/x.png', copiedToClipboard: true, soundPlayed: true);
        },
        settings: Settings(s),
        regionStore: LastRegionStore(s),
        shutter: () {},
        complete: () => completes++,
        showError: (_) {},
      );
      await dc.window();
      expect(deliveredWi, isNotNull);
      expect(deliveredWi!.width, 200);
      expect(completes, 1);
      final saved = await LastRegionStore(s).load();
      expect(saved!.rect, const Rect.fromLTWH(5, 6, 100, 80));
    });

    test('lastRegion(): no stored region -> no delivery, no sound', () async {
      final dc = build(frames: [_disp(1, cursor: true)]);
      await dc.lastRegion();
      expect(delivered, isEmpty);
      expect(shutters, 0);
    });

    test('lastRegion(): replays a stored rect', () async {
      final dc = build(frames: [_disp(1, cursor: true), _disp(2)]);
      await regionStore.save(
          const LastRegion(displayId: 2, rect: Rect.fromLTWH(7, 8, 200, 150)));
      await dc.lastRegion();
      expect(delivered.single.display.displayId, 2);
      expect(delivered.single.selectionLogical, const Rect.fromLTWH(7, 8, 200, 150));
    });
  });
}
