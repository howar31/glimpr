import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glimpr/capture/capture_bridge.dart';
import '../support/mock_channels.dart';

const _capture = MethodChannel('glimpr/capture');
const _overlay = MethodChannel('glimpr/overlay');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loupeSample passes the aim point and returns the patch', () async {
    final patch = Uint8List.fromList(List.filled(5 * 5 * 4, 0x7F));
    final calls = mockMethodChannel(_capture, handler: (_) => patch);
    final res = await CaptureBridge().loupeSample(10, 20, 5);
    expect(res, patch);
    final args = (calls.single.arguments as Map).cast<String, dynamic>();
    expect(args, {'x': 10, 'y': 20, 'span': 5});
  });

  test('recordSelection relays the region and one-shot overrides', () async {
    final calls = mockMethodChannel(_capture);
    await CaptureBridge().recordSelection(
      displayId: 4,
      rect: const Rect.fromLTWH(5, 6, 70, 80),
      title: 'Doc',
      app: 'App',
      showsCursor: true,
      gif: true,
      fps: 24,
      maxDuration: 30,
    );
    final args = (calls.single.arguments as Map).cast<String, dynamic>();
    expect(calls.single.method, 'recordSelection');
    expect(args['displayId'], 4);
    expect(args['x'], 5.0);
    expect(args['w'], 70.0);
    expect(args['title'], 'Doc');
    expect(args['app'], 'App');
    expect(args['showsCursor'], isTrue);
    expect(args['gif'], isTrue);
    expect(args['fps'], 24);
    expect(args['maxDuration'], 30);
    expect(args['cancelled'], isFalse);
    // Unset overrides stay ABSENT so the persisted settings apply.
    expect(args.containsKey('systemAudio'), isFalse);
    expect(args.containsKey('hevc'), isFalse);
    expect(args.containsKey('gifFps'), isFalse);
  });

  test('recordSelection cancel omits the rect', () async {
    final calls = mockMethodChannel(_capture);
    await CaptureBridge().recordSelection(displayId: 1, cancelled: true);
    final args = (calls.single.arguments as Map).cast<String, dynamic>();
    expect(args['cancelled'], isTrue);
    expect(args.containsKey('x'), isFalse);
  });

  test('elementSnapAt maps the native element and falls back on null/error',
      () async {
    mockMethodChannel(_capture, handler: (call) {
      expect((call.arguments as Map)['walk'], 2);
      return {
        'x': 10.0, 'y': 12.0, 'w': 100.0, 'h': 40.0,
        'level': 1, 'appliedWalk': 2,
      };
    });
    final snap = await CaptureBridge().elementSnapAt(1, 50, 60, walk: 2);
    expect(snap, isNotNull);
    expect(snap!.rect, const Rect.fromLTWH(10, 12, 100, 40));

    mockMethodChannel(_capture, handler: (_) => null);
    expect(await CaptureBridge().elementSnapAt(1, 50, 60), isNull);

    mockMethodChannel(_capture,
        handler: (_) => throw PlatformException(code: 'x'));
    expect(await CaptureBridge().elementSnapAt(1, 50, 60), isNull);
  });

  test('accessibility probes map replies and tolerate absence', () async {
    mockMethodChannel(_capture, handler: (_) => true);
    expect(await CaptureBridge().accessibilityTrusted(), isTrue);

    mockMethodChannel(_capture,
        handler: (_) => throw PlatformException(code: 'x'));
    expect(await CaptureBridge().accessibilityTrusted(), isFalse);

    // No channel at all: both probes stay silent.
    await CaptureBridge().requestAccessibility();
  });

  test('encodeHdrRegion returns the rendition and null on any miss', () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final calls = mockMethodChannel(_capture,
        handler: (_) => {'bytes': bytes, 'ext': 'heic'});
    final res = await CaptureBridge().encodeHdrRegion(
      displayId: 1,
      gen: 9,
      crop: const Rect.fromLTWH(0, 0, 10, 10),
      items: const [
        {'t': 'overlay'},
      ],
    );
    expect(res!.bytes, bytes);
    expect(res.ext, 'heic');
    final args = (calls.single.arguments as Map).cast<String, dynamic>();
    expect(args['gen'], 9);
    expect(args.containsKey('mask'), isFalse);

    mockMethodChannel(_capture, handler: (_) => {'ext': 'heic'});
    expect(
        await CaptureBridge().encodeHdrRegion(
          displayId: 1,
          gen: 1,
          crop: Rect.zero,
          items: const [],
        ),
        isNull);
  });

  test('simple channel verbs use their method names', () async {
    final calls = mockMethodChannel(_capture);
    final bridge = CaptureBridge();
    await bridge.stopLoupeFeed();
    await bridge.hideOverlayWindow();
    await bridge.openSettings();
    await bridge.setCursorHidden(true);
    await bridge.setDrawingLock(true);
    await bridge.recordSelectHotkey();
    await bridge.warpCursor(3, 4);
    await CaptureBridge.openInEditor('/tmp/a.png');
    await CaptureBridge.shareSheet('/tmp/a.png');
    await CaptureBridge.notifyRecentChanged();
    expect(calls.map((c) => c.method).toList(), [
      'stopLoupeFeed',
      'hideOverlay',
      'openSettings',
      'setCursorHidden',
      'setDrawingLock',
      'recordSelectHotkey',
      'warpCursor',
      'openInEditor',
      'shareSheet',
      'recentChanged',
    ]);
  });

  test('pinImage pins in place when a global rect is given', () async {
    final calls = mockMethodChannel(_capture);
    await CaptureBridge.pinImage('/tmp/a.png',
        globalRect: const Rect.fromLTWH(100, 50, 30, 20));
    var args = (calls.last.arguments as Map).cast<String, dynamic>();
    expect(args['path'], '/tmp/a.png');
    expect(args['x'], 100.0);
    expect(args['h'], 20.0);

    await CaptureBridge.pinImage('/tmp/b.png');
    args = (calls.last.arguments as Map).cast<String, dynamic>();
    expect(args.containsKey('x'), isFalse);
  });

  test('fire-and-forget helpers never throw without a host', () async {
    await CaptureBridge.setCaptureProcessing(true);
    await CaptureBridge.perfMark('testMark');
    await CaptureBridge().showError('boom');
  });

  test('setProcessing carries the localized tooltip label', () async {
    final calls = mockMethodChannel(_capture);
    await CaptureBridge.setCaptureProcessing(true);
    final args = (calls.single.arguments as Map).cast<String, dynamic>();
    expect(calls.single.method, 'setProcessing');
    expect(args['active'], isTrue);
    expect(args['label'], isNotEmpty);
  });

  test('broadcastEditorState forwards the state map', () async {
    final calls = mockMethodChannel(_capture);
    await CaptureBridge().broadcastEditorState({'tool': 'arrow'});
    expect(calls.single.method, 'broadcastEditorState');
    expect((calls.single.arguments as Map)['tool'], 'arrow');
  });

  test('registerOverlayHandlers dispatches the session events', () async {
    final active = <(int, Offset)>[];
    final states = <Map<String, dynamic>>[];
    var settingsOpen = 0, resume = 0, recordHotkey = 0;
    CaptureBridge().registerOverlayHandlers(
      onCaptureReady: (_, _, _) {},
      onActiveDisplay: (id, cursor) => active.add((id, cursor)),
      onEditorState: states.add,
      onSettingsOpen: () => settingsOpen++,
      onResume: () => resume++,
      onRecordSelectHotkey: () => recordHotkey++,
    );
    addTearDown(() => _overlay.setMethodCallHandler(null));

    await pushFromNative(_overlay, 'onActiveDisplay',
        {'activeId': 2, 'cursorX': 11.5, 'cursorY': 22.5});
    expect(active.single, (2, const Offset(11.5, 22.5)));

    await pushFromNative(_overlay, 'onEditorState', {'tool': 'pen'});
    expect(states.single['tool'], 'pen');

    await pushFromNative(_overlay, 'onSettingsOpen', null);
    await pushFromNative(_overlay, 'onResume', null);
    await pushFromNative(_overlay, 'onRecordSelectHotkey', null);
    expect((settingsOpen, resume, recordHotkey), (1, 1, 1));

    // Unknown pushes are ignored.
    await pushFromNative(_overlay, 'onWindowsRefreshed', null);
  });
}
