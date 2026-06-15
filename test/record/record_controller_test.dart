import 'dart:io';
import 'dart:ui' show Rect;
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/capture/captured_display.dart';
import 'package:glimpr/capture/last_region.dart';
import 'package:glimpr/output/flow.dart';
import 'package:glimpr/record/record_bridge.dart';
import 'package:glimpr/record/record_controller.dart';
import 'package:glimpr/settings/settings.dart';
import 'package:glimpr/settings/settings_store.dart';

class _FakeStore implements SettingsStore {
  _FakeStore([Map<String, Object>? seed]) {
    if (seed != null) _m.addAll(seed);
  }
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

/// Captures start/stop calls and exposes the registered event callbacks so
/// tests can drive the native lifecycle.
class _FakeBridge extends RecordBridge {
  final starts = <Map<String, dynamic>>[];
  var stops = 0;
  late void Function(int, Rect) started;
  late void Function(String) finished;
  late void Function(String) failed;
  late void Function() aborted;

  @override
  Future<void> start({
    required String mode,
    required String outputPath,
    int? displayId,
    Rect? rect,
    int? windowId,
    int fps = 30,
    bool hevc = false,
    bool gif = false,
    bool showsCursor = true,
    bool showScrim = true,
    bool systemAudio = false,
    bool microphone = false,
    int maxDuration = 0,
    int countdown = 0,
    String videoQuality = 'high',
    int maxLongSide = 0,
    int gifFps = 15,
  }) async {
    starts.add({
      'mode': mode,
      'outputPath': outputPath,
      'displayId': displayId,
      'rect': rect,
      'windowId': windowId,
      'fps': fps,
      'hevc': hevc,
      'gif': gif,
      'showsCursor': showsCursor,
      'showScrim': showScrim,
      'systemAudio': systemAudio,
      'microphone': microphone,
      'maxDuration': maxDuration,
      'countdown': countdown,
      'videoQuality': videoQuality,
      'maxLongSide': maxLongSide,
      'gifFps': gifFps,
    });
  }

  @override
  Future<void> stop() async => stops++;

  var pauses = 0;
  var resumes = 0;
  @override
  Future<void> pause() async => pauses++;
  @override
  Future<void> resume() async => resumes++;

  late void Function(Map<String, dynamic>) selection;
  late void Function() paused;
  late void Function() resumed;

  @override
  void registerHandlers({
    required void Function(int displayId, Rect rect) onStarted,
    required void Function(String path) onFinished,
    required void Function(String message) onFailed,
    required void Function() onAborted,
    void Function(Map<String, dynamic> args)? onSelection,
    void Function()? onPaused,
    void Function()? onResumed,
    void Function()? onStopping,
  }) {
    started = onStarted;
    finished = onFinished;
    failed = onFailed;
    aborted = onAborted;
    if (onSelection != null) selection = onSelection;
    if (onPaused != null) paused = onPaused;
    if (onResumed != null) resumed = onResumed;
  }
}

void main() {
  late _FakeStore store;
  late _FakeBridge bridge;
  late List<String> errors;
  late List<String> revealed;
  late List<String> copied;
  late List<String> shared;
  late int liveSelects;
  late int completes;
  late int recordHotkeys;

  RecordController build({FocusedWindowInfo? window}) {
    // Seed a temp save folder so the output-path leg never touches the real
    // ~/Pictures default from a unit test.
    store = _FakeStore({
      'save_directory':
          Directory.systemTemp.createTempSync('glimpr_rec_test').path,
    });
    bridge = _FakeBridge();
    errors = [];
    revealed = [];
    copied = [];
    shared = [];
    liveSelects = 0;
    completes = 0;
    recordHotkeys = 0;
    return RecordController(
      beginLiveSelect: () async => liveSelects++,
      recordSelectHotkey: () async => recordHotkeys++,
      complete: () => completes++,
      bridge: bridge,
      settings: Settings(store),
      focusedWindow: () async => window,
      regionStore: LastRegionStore(store, key: 'record_last_region'),
      showError: errors.add,
      copyTextFn: (t) async => copied.add(t),
      revealFn: (p) async => revealed.add(p),
      shareFn: (p) async => shared.add(p),
      now: () => DateTime(2026, 6, 12, 10, 30),
    );
  }

  group('RecordController', () {
    test('toggle(display) starts with defaults and the DISPLAY-named output',
        () async {
      final rc = build();
      await rc.toggle(kRecordModeDisplay);
      final s = bridge.starts.single;
      expect(s['mode'], kRecordModeDisplay);
      expect(s['outputPath'], endsWith('.mp4'));
      expect(s['outputPath'], contains('DISPLAY'));
      expect(s['fps'], 30);
      expect(s['hevc'], isFalse);
      expect(s['showsCursor'], isTrue);
      expect(s['systemAudio'], isFalse);
      expect(s['microphone'], isFalse);
      // Output quality defaults: high quality, 1920 long-side cap, GIF 15 fps,
      // high GIF quality (two-pass).
      expect(s['videoQuality'], 'high');
      expect(s['maxLongSide'], 1920);
      expect(s['gifFps'], 15);
      expect(rc.phase, RecordPhase.starting);
    });

    test('toggle while active stops instead of starting again', () async {
      final rc = build();
      await rc.toggle(kRecordModeDisplay);
      bridge.started(1, Rect.zero);
      expect(rc.phase, RecordPhase.recording);
      await rc.toggle(kRecordModeRegion); // ANY record action stops
      expect(bridge.stops, 1);
      expect(bridge.starts, hasLength(1));
    });

    test('pause moves to paused and calls the bridge; resume returns', () async {
      final rc = build();
      await rc.toggle(kRecordModeDisplay);
      bridge.started(1, Rect.zero);
      expect(rc.phase, RecordPhase.recording);
      await rc.pause();
      expect(rc.phase, RecordPhase.paused);
      expect(bridge.pauses, 1);
      await rc.resume();
      expect(rc.phase, RecordPhase.recording);
      expect(bridge.resumes, 1);
    });

    test('toggle while paused stops the session', () async {
      final rc = build();
      await rc.toggle(kRecordModeDisplay);
      bridge.started(1, Rect.zero);
      await rc.pause();
      await rc.toggle(kRecordModeDisplay);
      expect(bridge.stops, 1);
      expect(bridge.starts, hasLength(1));
    });

    test('native pause/resume events drive the phase', () async {
      final rc = build();
      await rc.toggle(kRecordModeDisplay);
      bridge.started(1, Rect.zero);
      bridge.paused();
      expect(rc.phase, RecordPhase.paused);
      bridge.resumed();
      expect(rc.phase, RecordPhase.recording);
    });

    test('pause is a no-op unless recording', () async {
      final rc = build();
      await rc.pause(); // idle
      expect(bridge.pauses, 0);
      expect(rc.phase, RecordPhase.idle);
    });

    test('recording settings flow through to the bridge', () async {
      final rc = build();
      final s = Settings(store);
      await s.setRecordFormat(RecordFormat.hevc);
      await s.setRecordFps(60);
      await s.setRecordShowCursor(false);
      await s.setRecordSystemAudio(true);
      await s.setRecordMicrophone(true);
      await s.setRecordScrim(false);
      await s.setRecordVideoQuality(RecordVideoQuality.low);
      await s.setRecordMaxLongSide(1280);
      await s.setRecordGifFps(25);
      await rc.toggle(kRecordModeDisplay);
      final call = bridge.starts.single;
      expect(call['hevc'], isTrue);
      expect(call['fps'], 60);
      expect(call['showsCursor'], isFalse);
      expect(call['systemAudio'], isTrue);
      expect(call['microphone'], isTrue);
      expect(call['showScrim'], isFalse);
      expect(call['videoQuality'], 'low');
      expect(call['maxLongSide'], 1280);
      expect(call['gifFps'], 25);
    });

    test('window mode with no focused window errors and stays idle', () async {
      final rc = build();
      await rc.toggle(kRecordModeWindow);
      expect(bridge.starts, isEmpty);
      expect(errors, hasLength(1));
      expect(rc.phase, RecordPhase.idle);
    });

    test('window mode passes the windowId and window-named output', () async {
      final rc = build(
        window: const FocusedWindowInfo(
            displayId: 2,
            rect: Rect.fromLTWH(0, 0, 10, 10),
            title: 'Safari',
            app: 'Safari',
            windowId: 42),
      );
      await rc.toggle(kRecordModeWindow);
      final s = bridge.starts.single;
      expect(s['windowId'], 42);
      expect(s['displayId'], 2);
      expect(s['outputPath'], contains('Safari'));
    });

    test('lastRegion: empty store is a silent no-op', () async {
      final rc = build();
      await rc.toggle(kRecordModeLastRegion);
      expect(bridge.starts, isEmpty);
      expect(errors, isEmpty);
      expect(rc.phase, RecordPhase.idle);
    });

    test('lastRegion replays the RECORD-own stored region', () async {
      final rc = build();
      await LastRegionStore(store, key: 'record_last_region').save(
          const LastRegion(displayId: 3, rect: Rect.fromLTWH(5, 6, 100, 80)));
      // The capture store must NOT leak into recording.
      await LastRegionStore(store).save(
          const LastRegion(displayId: 9, rect: Rect.fromLTWH(0, 0, 1, 1)));
      await rc.toggle(kRecordModeLastRegion);
      final s = bridge.starts.single;
      expect(s['displayId'], 3);
      expect(s['rect'], const Rect.fromLTWH(5, 6, 100, 80));
    });

    test('region toggle opens the live-select overlay, not a direct start',
        () async {
      final rc = build();
      await rc.toggle(kRecordModeRegion);
      expect(liveSelects, 1);
      expect(bridge.starts, isEmpty); // waits for the selection relay
      expect(rc.phase, RecordPhase.starting);
    });

    test('record hotkey during region picking routes to the overlay, not stop',
        () async {
      final rc = build();
      await rc.toggle(kRecordModeRegion); // -> starting (record-select picker up)
      expect(rc.phase, RecordPhase.starting);
      await rc.toggle(kRecordModeRegion); // hotkey again during region picking
      // The overlay decides (resurface a suspended picker / cancel a foreground
      // one); the controller does NOT blanket-cancel or stop here. The phase
      // stays starting until the overlay relays a cancel via recordSelection.
      expect(recordHotkeys, 1);
      expect(bridge.stops, 0);
      expect(rc.phase, RecordPhase.starting);
      expect(liveSelects, 1); // did NOT begin a second selection
      expect(bridge.starts, isEmpty);
    });

    test('overlay-relayed cancel after a hotkey idles the controller', () async {
      final rc = build();
      await rc.toggle(kRecordModeRegion);
      await rc.toggle(kRecordModeRegion); // hotkey -> overlay
      bridge.selection({'displayId': 1, 'cancelled': true}); // overlay cancelled
      await Future<void>.delayed(Duration.zero);
      expect(rc.phase, RecordPhase.idle);
      expect(bridge.starts, isEmpty);
    });

    test('record hotkey during the post-confirm countdown stops it', () async {
      final rc = build();
      await rc.toggle(kRecordModeRegion);
      bridge.selection({
        'displayId': 1, 'x': 0.0, 'y': 0.0, 'w': 100.0, 'h': 100.0,
      });
      await pumpEventQueue(times: 200); // -> start() issued; phase starting (countdown)
      expect(rc.phase, RecordPhase.starting);
      await rc.toggle(kRecordModeRegion); // hotkey during countdown = stop
      expect(bridge.stops, 1);
      expect(recordHotkeys, 0); // countdown path does NOT route to the overlay
      expect(rc.phase, RecordPhase.idle);
    });

    test('a relayed region selection starts the recording with its rect',
        () async {
      final rc = build();
      await rc.toggle(kRecordModeRegion);
      bridge.selection({
        'displayId': 2,
        'x': 5.0, 'y': 6.0, 'w': 100.0, 'h': 80.0,
      });
      await pumpEventQueue(times: 200);
      final s = bridge.starts.single;
      expect(s['mode'], kRecordModeRegion);
      expect(s['displayId'], 2);
      expect(s['rect'], const Rect.fromLTWH(5, 6, 100, 80));
      expect(s['outputPath'], contains('RECORDING'));
    });

    test('a relayed snap selection records a FIXED region, never the window',
        () async {
      final rc = build();
      await rc.toggle(kRecordModeRegion);
      // A snap arrives as the window's own rect (the overlay never relays a
      // windowId for region recording); it records that fixed rectangle and
      // does not follow the window. The window only names the output file.
      bridge.selection({
        'displayId': 1,
        'x': 10.0, 'y': 20.0, 'w': 300.0, 'h': 200.0,
        'title': 'Safari',
        'app': 'Safari',
      });
      await pumpEventQueue(times: 200);
      final s = bridge.starts.single;
      expect(s['mode'], kRecordModeRegion);
      expect(s['rect'], const Rect.fromLTWH(10, 20, 300, 200));
      expect(s['windowId'], isNull);
      expect(s['outputPath'], contains('Safari'));
    });

    test('a relayed no-selection confirm records the whole display', () async {
      final rc = build();
      await rc.toggle(kRecordModeRegion);
      bridge.selection({'displayId': 3});
      await pumpEventQueue(times: 200);
      final s = bridge.starts.single;
      expect(s['mode'], kRecordModeDisplay);
      expect(s['displayId'], 3);
      expect(s['outputPath'], contains('DISPLAY'));
    });

    test('a relayed selection honours the one-shot toolbar overrides',
        () async {
      final rc = build();
      await Settings(store).setRecordSystemAudio(false);
      await Settings(store).setRecordShowCursor(true);
      await rc.toggle(kRecordModeRegion);
      bridge.selection({
        'displayId': 1,
        'x': 0.0, 'y': 0.0, 'w': 100.0, 'h': 100.0,
        'showsCursor': false,
        'systemAudio': true,
        'microphone': true,
        'hevc': true,
        'fps': 60,
      });
      await pumpEventQueue(times: 200);
      final s = bridge.starts.single;
      expect(s['showsCursor'], isFalse); // override wins over the setting
      expect(s['systemAudio'], isTrue);
      expect(s['microphone'], isTrue);
      expect(s['hevc'], isTrue);
      expect(s['fps'], 60);
      // The persisted settings stayed untouched (one-shot only).
      expect(await Settings(store).getRecordSystemAudio(), isFalse);
    });

    test('gif format forces audio off and a .gif output', () async {
      final rc = build();
      await Settings(store).setRecordFormat(RecordFormat.gif);
      await Settings(store).setRecordSystemAudio(true);
      await Settings(store).setRecordMicrophone(true);
      await rc.toggle(kRecordModeDisplay);
      final s = bridge.starts.single;
      expect(s['gif'], isTrue);
      expect(s['systemAudio'], isFalse);
      expect(s['microphone'], isFalse);
      expect(s['outputPath'], endsWith('.gif'));
    });

    test('non-gif formats keep the mp4 output and audio settings', () async {
      final rc = build();
      await Settings(store).setRecordFormat(RecordFormat.hevc);
      await Settings(store).setRecordSystemAudio(true);
      await rc.toggle(kRecordModeDisplay);
      final s = bridge.starts.single;
      expect(s['gif'], isFalse);
      expect(s['hevc'], isTrue);
      expect(s['systemAudio'], isTrue);
      expect(s['outputPath'], endsWith('.mp4'));
    });

    test('maxDuration flows from settings to the bridge', () async {
      final rc = build();
      await Settings(store).setRecordMaxDuration(30);
      await rc.toggle(kRecordModeDisplay);
      expect(bridge.starts.single['maxDuration'], 30);
    });

    test('countdown flows from settings to the bridge', () async {
      final rc = build();
      await Settings(store).setRecordCountdown(5);
      await rc.toggle(kRecordModeDisplay);
      expect(bridge.starts.single['countdown'], 5);
    });

    test('per-take maxDuration override wins over the setting', () async {
      final rc = build();
      await Settings(store).setRecordMaxDuration(30);
      await rc.toggle(kRecordModeRegion);
      bridge.selection({
        'displayId': 1, 'x': 0.0, 'y': 0.0, 'w': 100.0, 'h': 100.0,
        'maxDuration': 5,
      });
      await pumpEventQueue(times: 200);
      expect(bridge.starts.single['maxDuration'], 5);
    });

    test('finishing plays the completion sound honouring the Sounds setting',
        () async {
      final rc = build();
      await rc.toggle(kRecordModeDisplay);
      bridge.started(1, Rect.zero);
      bridge.finished('/tmp/rec.mp4');
      await pumpEventQueue(times: 20);
      expect(completes, 1); // completion_sound defaults ON

      await Settings(store).setCompletionSound(false);
      await rc.toggle(kRecordModeDisplay);
      bridge.started(1, Rect.zero);
      bridge.finished('/tmp/rec2.mp4');
      await pumpEventQueue(times: 20);
      expect(completes, 1); // no second chime
    });

    test('a cancelled live-select returns to idle without starting', () async {
      final rc = build();
      await rc.toggle(kRecordModeRegion);
      bridge.selection({'displayId': 1, 'cancelled': true});
      await Future<void>.delayed(Duration.zero);
      expect(bridge.starts, isEmpty);
      expect(rc.phase, RecordPhase.idle);
      expect(errors, isEmpty);
    });

    test('onStarted persists the recorded region to the record store',
        () async {
      final rc = build();
      await rc.toggle(kRecordModeRegion);
      bridge.started(7, const Rect.fromLTWH(1, 2, 30, 40));
      await Future<void>.delayed(Duration.zero);
      final saved =
          await LastRegionStore(store, key: 'record_last_region').load();
      expect(saved!.displayId, 7);
      expect(saved.rect, const Rect.fromLTWH(1, 2, 30, 40));
      // The capture store stays untouched.
      expect(await LastRegionStore(store).load(), isNull);
      expect(rc.phase, RecordPhase.recording);
    });

    test('onFinished runs the configured after-recording flow then idles',
        () async {
      final rc = build();
      await Settings(store).setAfterRecordingFlow(
          {FlowAction.showInFinder, FlowAction.copyPath});
      await rc.toggle(kRecordModeDisplay);
      bridge.started(1, Rect.zero);
      bridge.finished('/tmp/rec.mp4');
      await Future<void>.delayed(Duration.zero);
      expect(revealed, ['/tmp/rec.mp4']);
      expect(copied, ['/tmp/rec.mp4']);
      expect(shared, isEmpty);
      expect(rc.phase, RecordPhase.idle);
    });

    test('default flow is NONE: silent save', () async {
      final rc = build();
      await rc.toggle(kRecordModeDisplay);
      bridge.started(1, Rect.zero);
      bridge.finished('/tmp/rec.mp4');
      await Future<void>.delayed(Duration.zero);
      expect(revealed, isEmpty);
      expect(copied, isEmpty);
      expect(shared, isEmpty);
    });

    test('onFailed surfaces the error and idles', () async {
      final rc = build();
      await rc.toggle(kRecordModeDisplay);
      bridge.failed('disk full');
      expect(errors.single, contains('disk full'));
      expect(rc.phase, RecordPhase.idle);
    });

    test('onAborted just idles (no error, no flow)', () async {
      final rc = build();
      await rc.toggle(kRecordModeDisplay);
      bridge.started(1, Rect.zero);
      bridge.aborted();
      expect(errors, isEmpty);
      expect(rc.phase, RecordPhase.idle);
    });
  });

  group('recording settings', () {
    test('setAfterRecordingFlow strips non-applicable legs', () async {
      final s = Settings(_FakeStore());
      await s.setAfterRecordingFlow({
        FlowAction.copy, // inapplicable to video
        FlowAction.save,
        FlowAction.pin,
        FlowAction.copyPath,
        FlowAction.shareSheet,
      });
      expect(await s.getAfterRecordingFlow(),
          {FlowAction.copyPath, FlowAction.shareSheet});
    });

    test('loadRecording round-trips and clamps fps', () async {
      final s = Settings(_FakeStore());
      await s.setRecordFps(45); // not a supported step -> clamps to 30
      var r = await s.loadRecording();
      expect(r.fps, 30);
      await s.setRecordFps(60);
      await s.setRecordFormat(RecordFormat.hevc);
      r = await s.loadRecording();
      expect(r.fps, 60);
      expect(r.hevc, isTrue);
      expect(r.showCursor, isTrue); // default on
    });

    test('record_format round-trips and defaults to h264', () async {
      final s = Settings(_FakeStore());
      expect((await s.loadRecording()).format, RecordFormat.h264);
      await s.setRecordFormat(RecordFormat.gif);
      expect((await s.loadRecording()).format, RecordFormat.gif);
    });

    test('record_max_duration round-trips, defaults 0, clamps off-steps',
        () async {
      final s = Settings(_FakeStore());
      expect((await s.loadRecording()).maxDuration, 0);
      await s.setRecordMaxDuration(15);
      expect((await s.loadRecording()).maxDuration, 15);
      await s.setRecordMaxDuration(7); // not a supported step -> 0 (off)
      expect((await s.loadRecording()).maxDuration, 0);
    });

    test('record_countdown round-trips, defaults 0, clamps off-steps',
        () async {
      final s = Settings(_FakeStore());
      expect((await s.loadRecording()).countdown, 0);
      await s.setRecordCountdown(3);
      expect((await s.loadRecording()).countdown, 3);
      await s.setRecordCountdown(7); // not a supported step -> 0 (off)
      expect((await s.loadRecording()).countdown, 0);
    });

    test('record_scrim round-trips and defaults to on', () async {
      final s = Settings(_FakeStore());
      expect((await s.loadRecording()).scrim, isTrue);
      await s.setRecordScrim(false);
      expect((await s.loadRecording()).scrim, isFalse);
    });
  });
}
