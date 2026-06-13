import 'dart:io';
import 'dart:ui' show Rect;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import '../capture/capture_bridge.dart';
import '../capture/direct_capture.dart'
    show kDisplayCaptureLabel, kLastRegionCaptureLabel;
import '../capture/captured_display.dart' show FocusedWindowInfo;
import '../capture/last_region.dart';
import '../output/deliver.dart' show effectiveSaveDir;
import '../output/filename.dart';
import '../output/flow.dart';
import '../output/sounds.dart';
import '../settings/settings.dart';
import 'record_bridge.dart';

/// Recording modes carried over the `glimpr/record` channel.
const kRecordModeRegion = 'region';
const kRecordModeWindow = 'window';
const kRecordModeDisplay = 'display';
const kRecordModeLastRegion = 'lastRegion';

/// Filename label for recordings with no window context (region/display).
const kRecordingCaptureLabel = 'RECORDING';

enum RecordPhase { idle, starting, recording, paused }

/// Control-engine recording orchestrator: TOGGLE semantics (a record action
/// starts when idle and stops the active recording otherwise — owner ruling),
/// output naming via the shared filename template, the record-own last-region
/// store, and the after-recording flow (path-based subset, default none).
/// Native owns the session itself (selector, stream, chrome) behind
/// [RecordBridge]; this class never touches video bytes.
class RecordController {
  RecordController({
    RecordBridge? bridge,
    Settings? settings,
    Future<FocusedWindowInfo?> Function()? focusedWindow,
    LastRegionStore? regionStore,
    void Function(String message)? showError,
    Future<void> Function(String text)? copyTextFn,
    Future<void> Function(String path)? revealFn,
    Future<void> Function(String path)? shareFn,
    Future<void> Function()? beginLiveSelect,
    Future<void> Function()? cancelLiveSelect,
    void Function()? complete,
    DateTime Function()? now,
  })  : _bridge = bridge ?? RecordBridge(),
        _settings = settings ?? Settings.instance,
        _focusedWindow = focusedWindow ?? CaptureBridge().focusedWindow,
        _regionStore = regionStore ??
            LastRegionStore(Settings.instance.store, key: 'record_last_region'),
        _showError = showError ?? ((m) => CaptureBridge().showError(m)),
        _copyText =
            copyTextFn ?? ((t) => Clipboard.setData(ClipboardData(text: t))),
        _reveal = revealFn ?? _revealInFinder,
        _share = shareFn ?? CaptureBridge.shareSheet,
        _beginLiveSelect = beginLiveSelect ??
            (() => CaptureBridge().beginCapture(liveSelect: true)),
        _cancelLiveSelect =
            cancelLiveSelect ?? (() => CaptureBridge().dismissOverlay()),
        _complete = complete ?? (() => playComplete()),
        _now = now ?? DateTime.now {
    _bridge.registerHandlers(
      onStarted: _onStarted,
      onFinished: _onFinished,
      onFailed: _onFailed,
      onAborted: _onAborted,
      onSelection: _onSelection,
      onPaused: _onPaused,
      onResumed: _onResumed,
    );
  }

  final RecordBridge _bridge;
  final Settings _settings;
  final Future<FocusedWindowInfo?> Function() _focusedWindow;
  final LastRegionStore _regionStore;
  final void Function(String) _showError;
  final Future<void> Function(String) _copyText;
  final Future<void> Function(String) _reveal;
  final Future<void> Function(String) _share;
  final Future<void> Function() _beginLiveSelect;
  final Future<void> Function() _cancelLiveSelect;
  final void Function() _complete;
  final DateTime Function() _now;

  RecordPhase _phase = RecordPhase.idle;
  RecordPhase get phase => _phase;
  bool get isActive => _phase != RecordPhase.idle;

  /// The hotkey/menu entry point: stop when a recording (or its selection) is
  /// in flight, start [mode] otherwise. Any record action stops the active
  /// session regardless of which mode started it; during the live-select
  /// phase it CANCELS the selection instead (nothing is recording yet).
  Future<void> toggle(String mode) async {
    if (_phase == RecordPhase.starting) {
      _phase = RecordPhase.idle;
      try {
        await _cancelLiveSelect();
      } catch (_) {}
      return;
    }
    if (isActive) {
      await _bridge.stop();
      return;
    }
    _phase = RecordPhase.starting;
    try {
      await _start(mode);
    } catch (e) {
      _phase = RecordPhase.idle;
      _showError('Recording failed: $e');
    }
  }

  /// Pause the active recording (no-op unless actively recording). The native
  /// side freezes the timeline so the result stays one continuous file.
  Future<void> pause() async {
    if (_phase != RecordPhase.recording) return;
    _phase = RecordPhase.paused;
    await _bridge.pause();
  }

  /// Resume a paused recording.
  Future<void> resume() async {
    if (_phase != RecordPhase.paused) return;
    _phase = RecordPhase.recording;
    await _bridge.resume();
  }

  void _onPaused() {
    if (_phase == RecordPhase.recording) _phase = RecordPhase.paused;
  }

  void _onResumed() {
    if (_phase == RecordPhase.paused) _phase = RecordPhase.recording;
  }

  Future<void> _start(String mode) async {
    if (mode == kRecordModeRegion) {
      // Region selection = the overlay's LIVE-SELECT session (owner mandate:
      // capture/recording share ONE selection UI — crosshair/loupe/snap).
      // The confirmed target arrives via _onSelection; Esc cancels there too.
      await _beginLiveSelect();
      return;
    }
    final cap = await _settings.loadCapture();
    final rec = await _settings.loadRecording();

    String? title;
    String? app;
    int? displayId;
    int? windowId;
    Rect? rect;
    switch (mode) {
      case kRecordModeWindow:
        final info = await _focusedWindow();
        if (info?.windowId == null) {
          _phase = RecordPhase.idle;
          _showError('No window to record');
          return;
        }
        windowId = info!.windowId;
        displayId = info.displayId;
        title = info.title.isEmpty ? null : info.title;
        app = info.app.isEmpty ? null : info.app;
      case kRecordModeLastRegion:
        final r = await _regionStore.load();
        if (r == null) {
          _phase = RecordPhase.idle;
          return; // nothing stored -> silent no-op (parity with ⌘⌥4)
        }
        displayId = r.displayId;
        rect = r.rect;
        title = kLastRegionCaptureLabel;
        app = kLastRegionCaptureLabel;
      case kRecordModeDisplay:
        title = kDisplayCaptureLabel;
        app = kDisplayCaptureLabel;
      default: // region: native live selector picks display + rect
        title = kRecordingCaptureLabel;
        app = kRecordingCaptureLabel;
    }

    final isGif = rec.isGif;
    final fileName = buildScreenshotName(
      template: cap.filenameTemplate,
      t: _now(),
      windowTitle: title,
      appName: app,
      ext: isGif ? 'gif' : 'mp4',
    );
    final dir = effectiveSaveDir(cap.saveDir);
    await dir.create(recursive: true);
    await _bridge.start(
      mode: mode,
      outputPath: '${dir.path}/$fileName',
      displayId: displayId,
      rect: rect,
      windowId: windowId,
      fps: rec.fps,
      hevc: rec.hevc,
      gif: isGif,
      showsCursor: rec.showCursor,
      // GIF has no audio track.
      systemAudio: isGif ? false : rec.systemAudio,
      microphone: isGif ? false : rec.microphone,
      maxDuration: rec.maxDuration,
      countdown: rec.countdown,
    );
  }

  /// A live-select confirm/cancel relayed from the overlay. A snap click
  /// records the WINDOW (the stream follows it); a drag records the fixed
  /// region; no selection records the whole display.
  Future<void> _onSelection(Map<String, dynamic> a) async {
    if ((a['cancelled'] as bool?) ?? false) {
      _phase = RecordPhase.idle;
      return;
    }
    if (_phase == RecordPhase.recording) return; // already recording
    _phase = RecordPhase.starting;
    try {
      final cap = await _settings.loadCapture();
      final rec = await _settings.loadRecording();
      final displayId = (a['displayId'] as num?)?.toInt();
      final windowId = (a['windowId'] as num?)?.toInt();
      Rect? rect;
      if (a['x'] != null) {
        rect = Rect.fromLTWH(
          (a['x'] as num).toDouble(),
          (a['y'] as num).toDouble(),
          (a['w'] as num).toDouble(),
          (a['h'] as num).toDouble(),
        );
      }
      final mode = windowId != null
          ? kRecordModeWindow
          : (rect != null ? kRecordModeRegion : kRecordModeDisplay);
      final title = (a['title'] as String?) ??
          (rect != null ? kRecordingCaptureLabel : kDisplayCaptureLabel);
      final app = (a['app'] as String?) ?? title;
      final isGif = (a['gif'] as bool?) ?? rec.isGif;
      final fileName = buildScreenshotName(
        template: cap.filenameTemplate,
        t: _now(),
        windowTitle: title.isEmpty ? null : title,
        appName: app.isEmpty ? null : app,
        ext: isGif ? 'gif' : 'mp4',
      );
      final dir = effectiveSaveDir(cap.saveDir);
      await dir.create(recursive: true);
      await _bridge.start(
        mode: mode,
        outputPath: '${dir.path}/$fileName',
        displayId: displayId,
        rect: rect,
        windowId: windowId,
        // The live-select toolbar's one-shot overrides win over the settings.
        fps: (a['fps'] as num?)?.toInt() ?? rec.fps,
        hevc: (a['hevc'] as bool?) ?? rec.hevc,
        gif: isGif,
        showsCursor: (a['showsCursor'] as bool?) ?? rec.showCursor,
        // GIF has no audio track.
        systemAudio: isGif ? false : (a['systemAudio'] as bool?) ?? rec.systemAudio,
        microphone: isGif ? false : (a['microphone'] as bool?) ?? rec.microphone,
        maxDuration: (a['maxDuration'] as num?)?.toInt() ?? rec.maxDuration,
        countdown: rec.countdown,
      );
    } catch (e) {
      _phase = RecordPhase.idle;
      _showError('Recording failed: $e');
    }
  }

  void _onStarted(int displayId, Rect rect) {
    _phase = RecordPhase.recording;
    if (rect.width > 0 && rect.height > 0) {
      // Best-effort bookkeeping for "Record Last Region".
      _regionStore.save(LastRegion(displayId: displayId, rect: rect));
    }
  }

  Future<void> _onFinished(String path) async {
    _phase = RecordPhase.idle;
    if (path.isEmpty) return;
    // No shutter at recording start (owner design); the COMPLETION sound
    // marks a finished recording, honouring the shared Sounds setting.
    if ((await _settings.loadCapture()).completionSound) _complete();
    final flow = (await _settings.loadRecording()).flow;
    if (flow.contains(FlowAction.copyPath)) {
      try {
        await _copyText(path);
      } catch (_) {}
    }
    if (flow.contains(FlowAction.showInFinder)) {
      try {
        await _reveal(path);
      } catch (_) {}
    }
    if (flow.contains(FlowAction.shareSheet)) {
      try {
        await _share(path);
      } catch (_) {}
    }
  }

  void _onFailed(String message) {
    _phase = RecordPhase.idle;
    _showError('Recording failed: $message');
  }

  void _onAborted() {
    _phase = RecordPhase.idle;
  }

  static Future<void> _revealInFinder(String path) async {
    await Process.run('open', ['-R', path]);
  }
}
