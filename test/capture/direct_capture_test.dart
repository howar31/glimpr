import 'dart:typed_data';
import 'dart:ui' show Offset, Rect;
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/capture/capture_kind.dart';
import 'package:glimpr/capture/captured_display.dart';
import 'package:glimpr/capture/direct_capture.dart';
import 'package:glimpr/capture/last_region.dart';
import 'package:glimpr/editor/decoration.dart';
import 'package:glimpr/output/deliver.dart';
import 'package:glimpr/output/flow.dart';
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

RegionCapture _rc(int displayId, Rect? rect) => RegionCapture(
      bytes: Uint8List(0),
      displayId: displayId,
      rect: rect ?? const Rect.fromLTWH(0, 0, 1920, 1080),
      displayOrigin: const Offset(0, 0),
      scaleFactor: 2,
    );

void main() {
  group('DirectCapture orchestrator', () {
    late _FakeStore store;
    late LastRegionStore regionStore;
    late List<({int? displayId, Rect? rect})> regionCalls;
    late List<Map<String, dynamic>?> regionDecorations;
    late List<bool> regionAlsoPlain;
    late List<({RegionCapture c, CaptureKind kind, String? title, String? app})>
        delivered;
    late int shutters;
    late int completes;
    late List<String> errors;
    late List<String> marks;

    DirectCapture build({
      FocusedWindowInfo? window,
      // null -> echo a capture for whatever was asked; otherwise decides per
      // call (return null = "display gone").
      RegionCapture? Function(int? displayId, Rect? rect)? onRegion,
    }) {
      store = _FakeStore();
      regionStore = LastRegionStore(store);
      regionCalls = [];
      regionDecorations = [];
      regionAlsoPlain = [];
      delivered = [];
      shutters = 0;
      completes = 0;
      errors = [];
      marks = [];
      return DirectCapture(
        captureRegion: ({displayId, rect, showsCursor = false, jpeg = false,
            jpegQuality = 90, decoration, alsoPlain = false,
            hdr = false, alsoCopy = false}) async {
          regionCalls.add((displayId: displayId, rect: rect));
          regionDecorations.add(decoration);
          regionAlsoPlain.add(alsoPlain);
          if (onRegion != null) return onRegion(displayId, rect);
          return _rc(displayId ?? 1, rect);
        },
        focusedWindow: () async => window,
        settings: Settings(store),
        regionStore: regionStore,
        deliverEncoded: (c, cap, kind, title, app) async {
          delivered.add((c: c, kind: kind, title: title, app: app));
          return const FlowResult(DeliveryResult(
              savedPath: '/tmp/x.png', copiedToClipboard: true, soundPlayed: false));
        },
        shutter: () => shutters++,
        complete: () => completes++,
        showError: (m) => errors.add(m),
        perfMark: (label) => marks.add(label),
      );
    }

    test('screen(): bare captureRegion, DISPLAY labels, records full region',
        () async {
      final dc = build();
      await dc.screen();
      expect(regionCalls.single, (displayId: null, rect: null));
      expect(delivered.single.kind, CaptureKind.display);
      expect(delivered.single.title, 'DISPLAY');
      expect(delivered.single.app, 'DISPLAY');
      expect(shutters, 1);
      expect(completes, 1);
      expect(marks, ['directDelivered ok=true kind=display']);
      final saved = await regionStore.load();
      expect(saved!.displayId, 1);
      expect(saved.rect, const Rect.fromLTWH(0, 0, 1920, 1080));
    });

    test('decoration off (default): no decoration spec passed to captureRegion',
        () async {
      final dc = build();
      await dc.screen();
      expect(regionDecorations.single, isNull);
    });

    test('decoration on for the kind: logical spec passed to captureRegion',
        () async {
      final dc = build();
      await Settings(store).setDecorateDisplay(true);
      await dc.screen();
      final spec = regionDecorations.single;
      expect(spec, isNotNull);
      expect(spec!['margin'], kDecorMarginLogical);
      expect(spec['cornerRadius'], kDecorCornerRadiusLogical);
      expect(spec['shapeFromAlpha'], false);
      // PNG (default): no opaque fill -> margins stay transparent.
      expect(spec.containsKey('fill'), false);
      // No pin in the default flow -> no plain rendition requested.
      expect(regionAlsoPlain.single, isFalse);
    });

    test('decoration on + pin in flow: captureRegion gets alsoPlain', () async {
      final dc = build();
      await Settings(store).setDecorateDisplay(true);
      await Settings(store).setAfterCaptureFlow(
          {FlowAction.save, FlowAction.pin});
      await dc.screen();
      expect(regionDecorations.single, isNotNull);
      expect(regionAlsoPlain.single, isTrue);
    });

    test('decoration on + pin-only flow: decoration skipped, no alsoPlain',
        () async {
      final dc = build();
      await Settings(store).setDecorateDisplay(true);
      await Settings(store).setAfterCaptureFlow({FlowAction.pin});
      await dc.screen();
      expect(regionDecorations.single, isNull);
      expect(regionAlsoPlain.single, isFalse);
    });

    test('RegionCapture.fromMap carries the optional plainBytes', () {
      final m = <dynamic, dynamic>{
        'bytes': Uint8List.fromList([1]),
        'plainBytes': Uint8List.fromList([2]),
        'displayId': 1,
        'x': 0.0, 'y': 0.0, 'w': 10.0, 'h': 10.0,
        'left': 0.0, 'top': 0.0, 'scaleFactor': 2.0,
      };
      expect(RegionCapture.fromMap(m).plainBytes, [2]);
      m.remove('plainBytes');
      expect(RegionCapture.fromMap(m).plainBytes, isNull);
    });

    test('window(): fallback passes the focused displayId+rect', () async {
      final dc = build(
        window: const FocusedWindowInfo(
            displayId: 2,
            rect: Rect.fromLTWH(5, 6, 100, 80),
            title: 'W',
            app: 'A'),
      );
      await dc.window();
      expect(regionCalls.single,
          (displayId: 2, rect: const Rect.fromLTWH(5, 6, 100, 80)));
      expect(delivered.single.kind, CaptureKind.focusedWindow);
      expect(delivered.single.title, 'W');
      expect(delivered.single.app, 'A');
      final saved = await regionStore.load();
      expect(saved!.rect, const Rect.fromLTWH(5, 6, 100, 80));
    });

    test('window(): no focused window -> bare capture with DISPLAY labels',
        () async {
      final dc = build();
      await dc.window();
      expect(regionCalls.single, (displayId: null, rect: null));
      expect(delivered.single.kind, CaptureKind.display);
      expect(delivered.single.title, 'DISPLAY');
    });

    test('window(): focused display gone -> retries bare on the cursor display',
        () async {
      final dc = build(
        window: const FocusedWindowInfo(
            displayId: 99,
            rect: Rect.fromLTWH(0, 0, 10, 10),
            title: 'W',
            app: 'A'),
        onRegion: (displayId, rect) =>
            displayId == null ? _rc(1, rect) : null, // 99 is gone
      );
      await dc.window();
      expect(regionCalls, hasLength(2));
      expect(regionCalls.last, (displayId: null, rect: null));
      expect(delivered.single.kind, CaptureKind.display);
      expect(delivered.single.title, 'DISPLAY');
      expect(errors, isEmpty);
    });

    test('window(): delivers the native final bytes when a windowId is present',
        () async {
      final s = _FakeStore();
      Uint8List? deliveredBytes;
      Map<String, dynamic>? passedDecoration;
      var completes = 0;
      final dc = DirectCapture(
        focusedWindow: () async => const FocusedWindowInfo(
            displayId: 1,
            rect: Rect.fromLTWH(5, 6, 100, 80),
            title: 'W',
            app: 'App',
            windowId: 99),
        captureWindowDelivered: (id,
            {bool showsCursor = false,
            bool jpeg = false,
            int jpegQuality = 90,
            Map<String, dynamic>? decoration,
            bool alsoPlain = false,
            bool hdr = false,
            bool alsoCopy = false}) async {
          expect(id, 99);
          passedDecoration = decoration;
          return (
            bytes: Uint8List.fromList([1, 2, 3]),
            plainBytes: null,
            hdrBytes: null,
            copied: false,
            hdrExt: null,
          );
        },
        deliverWindow: (bytes, cap, info,
            {pinBytes, hdrBytes, hdrExt, preCopied = false}) async {
          deliveredBytes = bytes;
          return const FlowResult(DeliveryResult(
              savedPath: '/x.png', copiedToClipboard: true, soundPlayed: true));
        },
        settings: Settings(s),
        regionStore: LastRegionStore(s),
        shutter: () {},
        complete: () => completes++,
        showError: (_) {},
        perfMark: (_) {},
      );
      await dc.window();
      expect(deliveredBytes, Uint8List.fromList([1, 2, 3]));
      expect(passedDecoration, isNull); // decoration off by default
      expect(completes, 1);
      final saved = await LastRegionStore(s).load();
      expect(saved!.rect, const Rect.fromLTWH(5, 6, 100, 80));
    });

    test('window(): decoration on -> alpha-shape spec passed to native', () async {
      final s = _FakeStore();
      await Settings(s).setDecorateWindow(true);
      Map<String, dynamic>? passedDecoration;
      final dc = DirectCapture(
        focusedWindow: () async => const FocusedWindowInfo(
            displayId: 1,
            rect: Rect.fromLTWH(5, 6, 100, 80),
            title: 'W',
            app: 'App',
            windowId: 99),
        captureWindowDelivered: (id,
            {bool showsCursor = false,
            bool jpeg = false,
            int jpegQuality = 90,
            Map<String, dynamic>? decoration,
            bool alsoPlain = false,
            bool hdr = false,
            bool alsoCopy = false}) async {
          passedDecoration = decoration;
          return (
            bytes: Uint8List.fromList([1]),
            plainBytes: null,
            hdrBytes: null,
            copied: false,
            hdrExt: null,
          );
        },
        deliverWindow: (bytes, cap, info,
            {pinBytes, hdrBytes, hdrExt, preCopied = false}) async =>
            const FlowResult(DeliveryResult(
                savedPath: '/x.png',
                copiedToClipboard: true,
                soundPlayed: true)),
        settings: Settings(s),
        regionStore: LastRegionStore(s),
        shutter: () {},
        complete: () {},
        showError: (_) {},
        perfMark: (_) {},
      );
      await dc.window();
      expect(passedDecoration, isNotNull);
      expect(passedDecoration!['shapeFromAlpha'], true);
      expect(passedDecoration!['margin'], kDecorMarginLogical);
    });

    test('window(): decoration on + pin in flow -> alsoPlain, plain bytes '
        'reach delivery', () async {
      final s = _FakeStore();
      await Settings(s).setDecorateWindow(true);
      await Settings(s)
          .setAfterCaptureFlow({FlowAction.save, FlowAction.pin});
      final plain = Uint8List.fromList([7, 7]);
      bool? passedAlsoPlain;
      Uint8List? deliveredPin;
      final dc = DirectCapture(
        focusedWindow: () async => const FocusedWindowInfo(
            displayId: 1,
            rect: Rect.fromLTWH(5, 6, 100, 80),
            title: 'W',
            app: 'App',
            windowId: 99),
        captureWindowDelivered: (id,
            {bool showsCursor = false,
            bool jpeg = false,
            int jpegQuality = 90,
            Map<String, dynamic>? decoration,
            bool alsoPlain = false,
            bool hdr = false,
            bool alsoCopy = false}) async {
          passedAlsoPlain = alsoPlain;
          return (
            bytes: Uint8List.fromList([1]),
            plainBytes: plain,
            hdrBytes: null,
            copied: false,
            hdrExt: null,
          );
        },
        deliverWindow: (bytes, cap, info,
            {pinBytes, hdrBytes, hdrExt, preCopied = false}) async {
          deliveredPin = pinBytes;
          return const FlowResult(DeliveryResult(
              savedPath: '/x.png',
              copiedToClipboard: true,
              soundPlayed: true));
        },
        settings: Settings(s),
        regionStore: LastRegionStore(s),
        shutter: () {},
        complete: () {},
        showError: (_) {},
        perfMark: (_) {},
      );
      await dc.window();
      expect(passedAlsoPlain, isTrue);
      expect(deliveredPin, plain);
    });

    test('lastRegion(): no stored region -> no capture, no sound, no mark',
        () async {
      final dc = build();
      await dc.lastRegion();
      expect(regionCalls, isEmpty);
      expect(delivered, isEmpty);
      expect(shutters, 0);
      expect(marks, isEmpty);
    });

    test('lastRegion(): replays the stored rect with LAST labels', () async {
      final dc = build();
      await regionStore.save(
          const LastRegion(displayId: 2, rect: Rect.fromLTWH(7, 8, 200, 150)));
      await dc.lastRegion();
      expect(regionCalls.single,
          (displayId: 2, rect: const Rect.fromLTWH(7, 8, 200, 150)));
      expect(delivered.single.kind, CaptureKind.lastRegion);
      expect(delivered.single.title, 'LAST');
      expect(marks, ['directDelivered ok=true kind=lastRegion']);
    });

    test('lastRegion(): stored display gone -> silent no-op', () async {
      final dc = build(onRegion: (displayId, rect) => null);
      await regionStore.save(
          const LastRegion(displayId: 99, rect: Rect.fromLTWH(0, 0, 5, 5)));
      await dc.lastRegion();
      expect(regionCalls, hasLength(1));
      expect(delivered, isEmpty);
      expect(shutters, 0);
      expect(errors, isEmpty);
      expect(marks, isEmpty);
    });
  });
}
