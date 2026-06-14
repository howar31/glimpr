import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../capture/capture_bridge.dart';
import '../capture/capture_kind.dart';
import '../perf/frame_stats.dart';
import '../capture/captured_display.dart';
import '../capture/last_region.dart';
import '../l10n/gen/app_localizations.dart';
import '../theme/glimpr_theme.dart';
import '../settings/app_locale.dart';
import '../editor/draw_style.dart';
import '../editor/editor_controller.dart';
import '../editor/hud_config.dart';
import '../editor/loupe_config.dart';
import '../editor/tool_style_store.dart';
import '../output/flow.dart';
import 'toolbar.dart' show RecordOverrides;
import '../output/sounds.dart';
import '../settings/settings.dart';
import '../settings/settings_mask.dart';
import '../theme/confirm_dialog.dart';
import '../shortcuts/hotkey_binding.dart';
import '../shortcuts/shortcut_actions.dart';
import '../shortcuts/shortcut_store.dart';
import 'editor_canvas.dart';
import 'export.dart';
import 'session_layers.dart';
import 'session_op_log.dart';

/// Record-select overlay state. `active` = the crop region picker is foreground
/// (layered OVER the live session, which renders presentation-only beneath);
/// `suspended` = a freeze layer was taken on top of it (the picker's visual is
/// baked into that freeze frame), so it waits to be restored; `none` = no
/// pending recording selection. Orthogonal to the freeze [LayerStack]: a
/// record-select NEVER enters that stack.
enum RecordSelectState { none, active, suspended }

/// The per-display overlay engine's app. Idle = transparent; on capture it hosts
/// the annotation editor (EditorCanvas) over the frozen image and, on export,
/// composites the annotations + crops + delivers (file/clipboard/sound).
class OverlayApp extends StatefulWidget {
  const OverlayApp({super.key});
  @override
  State<OverlayApp> createState() => _OverlayAppState();
}

class _OverlayAppState extends State<OverlayApp> {
  final _bridge = CaptureBridge();
  CapturedDisplay? _display;
  ui.Image? _frozen; // decoded once per capture, used for export compositing
  // The captured OS mouse pointer (toggleable cursor layer) decoded per capture +
  // its display-local LOGICAL top-left; null when the capture had no cursor.
  ui.Image? _cursorImage;
  Offset? _cursorTopLeft;
  // Capture-time settings, prefetched per capture (in onCaptured) so the
  // shutter sound + delivery never await the store on the commit hot path.
  CaptureSettings _capture = CaptureSettings.defaults;
  // Effective editor.* hotkey bindings, prefetched per capture (in onCaptured)
  // so EditorCanvas's _onKey reads them live on each rebuild without awaiting.
  // Seeded with the factory defaults so editor shortcuts work the instant the
  // first overlay appears (the async load below only layers in user overrides);
  // ShortcutStore.all() returns the same merged shape.
  Map<String, HotkeyBinding?> _editorBindings = {...kDefaultBindings};
  LoupeConfig _loupe = const LoupeConfig();
  HudConfig _hud = const HudConfig();
  // Navigator for the exit-confirmation dialog; re-entrancy guard so a second
  // Esc / right-click while it's open never stacks dialogs.
  final _navigatorKey = GlobalKey<NavigatorState>();
  bool _confirmingExit = false;
  // True while a ⌘, Settings detour has paused this freeze -> show the dim mask.
  bool _settingsOpen = false;
  EditorController? _editor;
  // Last-used style per tool, persisted across captures (in-session).
  final Map<ToolKind, DrawStyle> _toolStyles = {};
  // The native cursor poll's single source of truth: which display is the active
  // editor + the cursor's display-local point. Every engine's EditorCanvas reads
  // this and shows its HUD only when the id matches its own display.
  final ValueNotifier<({int id, Offset cursor})> _activeSignal = ValueNotifier((
    id: -1,
    cursor: Offset.zero,
  ));
  // True while applying a tool/style update received from another display, so it
  // is not re-broadcast back (avoids a sync loop).
  bool _applyingRemote = false;
  // Increments each capture so EditorCanvas is rebuilt fresh (see onCaptureReady).
  int _captureSeq = 0;
  // The ⌘⌥5 "capture to pin" mode: this session's confirm runs ONLY the pin
  // action instead of the configured after-capture flow.
  bool _pinOnly = false;
  // Record-select (RS): an ADDITIVE crop-only region picker layered OVER the
  // live session (which stays intact, rendered presentation-only beneath).
  // Orthogonal to the freeze LayerStack — it never enters it.
  RecordSelectState _rs = RecordSelectState.none;
  CapturedDisplay? _recordDisplay; // RS layer's display geometry (this engine)
  ui.Image? _recordStub; // 1x1 transparent base image for the RS crop editor
  EditorController? _recordEditor; // crop-only; NOT in the cross-display sync
  // Last live/RS display geometry, kept so a suspended RS can be re-armed when
  // the freeze layer above it is resolved and the live slot is cleared.
  CapturedDisplay? _lastKnownDisplay;
  // One-shot per-recording overrides (toolbar toggles), seeded from the
  // Recording settings each record-select; read at confirm, never persisted.
  RecordOverrides? _recordOverrides;
  // Capture layer stack: suspended sessions below the live one. Capacity is
  // re-read from Settings on every capture; 1 = no stacking (live layer is
  // replaced, today's behavior). Each layer is an independent run of
  // freeze -> annotate -> output; the frozen image of layer N deliberately
  // CONTAINS layer N-1's rendering (capture-faithful, owner design).
  final LayerStack<_SessionLayer> _layers = LayerStack(1);
  // Toolbar caption state: null = hidden; accent marks a 3s replace notice.
  String? _layerCaption;
  bool _layerAccent = false;
  Timer? _layerNoticeTimer;
  // Debounce timer for persisting _toolStyles to the store.
  Timer? _persistTimer;
  // Perf instrumentation: per-interaction frame summaries + the cross-display
  // broadcast rate, dropped into the unified-log perf marks (M1/M2/M6/M8 in
  // the perf-tune plan). Silent at idle — engines only render on change.
  late final FrameStatsReporter _frames =
      FrameStatsReporter(tag: 'overlay', sink: _perfSink);
  int _broadcastCount = 0;
  Timer? _broadcastRateTimer;
  // F1-2 throttle state: quiet-window timer + a pending coalesced change.
  Timer? _broadcastTimer;
  bool _broadcastDirty = false;
  // Display ids of OTHER engines holding unsaved annotations. Drawables never
  // sync across displays, so a clean display's Esc/right-click would otherwise
  // silently discard another display's work (dismissOverlay is session-wide).
  // Each engine broadcasts its own empty<->non-empty transitions immediately
  // (rare, so they bypass the style throttle).
  final Set<int> _remoteDirty = {};
  bool _localDirty = false;
  // Session-global undo/redo: every engine keeps an identical replica of the
  // session op log; ⌘Z/⇧⌘Z anywhere target the SESSION's latest op and route
  // to the owning display (see SessionOpLog). _lastDepth detects local
  // commits (unguarded history-depth +1); _applyingProtocol marks document
  // changes driven by the protocol itself (remote undo/redo, redo-tail
  // clears) so they are not re-broadcast as new ops. Non-final: each capture
  // LAYER owns its own op log instance (swapped on suspend/resume).
  SessionOpLog _opLog = SessionOpLog();
  int _lastDepth = 1;
  bool _applyingProtocol = false;
  // Session-global single selection: a claim on one display clears the others.
  bool _applyingRemoteSel = false;

  void _perfSink(String label) {
    CaptureBridge.perfMark(label).then((_) {}, onError: (_) {});
  }

  @override
  void initState() {
    super.initState();
    _frames.attach();
    _bridge.registerOverlayHandlers(
      onCaptureReady: (d, pinOnly, liveSelect) async {
        if (liveSelect) {
          // Recording region selection is an ADDITIVE overlay that NEVER
          // touches the live screenshot/pin session (the old bug disposed it).
          await _beginRecordSelect(d);
          return;
        }
        // A screenshot taken while a record-select is foreground suspends it
        // (its crosshair/veil is frozen INTO this capture as content); it is
        // restored when this freeze layer (and any above it) is resolved.
        // onCaptureReady fires on EVERY engine, so each suspends its own RS
        // locally — no broadcast needed.
        if (_rs == RecordSelectState.active) {
          _suspendRecordSelect();
        }
        // NOTE: _pinOnly is set AFTER the suspend decision below — the
        // suspended layer must keep ITS OWN pin flag.
        // Reseed per-tool styles from disk on EVERY capture so a Settings
        // "Reset all tool styles" (or an edit made on another engine) takes
        // effect on THIS capture — not only after a restart. Kicked off now and
        // awaited just before the controller is built, so its latency hides
        // behind the image decode below (no added reveal delay).
        final stylesFuture = _loadToolStyles();
        // Layer cap for the suspend-vs-replace decision; read per capture so
        // a Settings change applies without a restart.
        final layerCapFuture = Settings.instance.getCaptureLayerCap();
        // Raw BGRA pixels -> ui.Image (no codec): a pixel upload, not a PNG
        // decode — this is the freeze path's cheap step.
        ui.Image? frozen;
        try {
          final completer = Completer<ui.Image>();
          ui.decodeImageFromPixels(
            d.rawBytes, d.pixelWidth, d.pixelHeight, ui.PixelFormat.bgra8888,
            completer.complete, rowBytes: d.rowBytes,
          );
          frozen = await completer.future;
        } catch (_) {
          // Without a frozen image the overlay presents with no base layer and
          // the export is skipped — practically unreachable for raw pixels.
        }
        // Decode the OS cursor image (toggleable layer), if any.
        ui.Image? cursorImg;
        final cursorBytes = d.cursorImageBytes;
        if (cursorBytes != null) {
          try {
            final codec = await ui.instantiateImageCodec(cursorBytes);
            cursorImg = (await codec.getNextFrame()).image;
            codec.dispose();
          } catch (_) {/* no cursor layer on decode failure */}
        }
        final cursorTl = (d.cursorLeft != null && d.cursorTop != null)
            ? Offset(d.cursorLeft!, d.cursorTop!)
            : null;
        final loadedStyles = await stylesFuture;
        if (!mounted) return;
        _layers.capacity = await layerCapFuture;
        var replaced = false;
        var evicted = false;
        final live = _display != null && _editor != null && _frozen != null;
        if (live && _layers.capacity > 1) {
          // Stack the live layer under the new one (a trigger never destroys
          // current work at cap >= 2). At the cap the OLDEST suspended layer
          // is evicted instead, so the stack always holds the most recent
          // layers (owner decision; the while covers a cap lowered between
          // captures). Detach first: a suspended controller must not
          // broadcast or persist.
          while (!_layers.canSuspend) {
            final dropped = _layers.dropOldest();
            if (dropped == null) break;
            dropped.disposeAll();
            evicted = true;
          }
          _detachShared();
          _layers.suspend(_SessionLayer(
            display: _display!,
            frozen: _frozen!,
            cursorImage: _cursorImage,
            cursorTopLeft: _cursorTopLeft,
            editor: _editor!,
            opLog: _opLog,
            remoteDirty: Set.of(_remoteDirty),
            localDirty: _localDirty,
            lastDepth: _lastDepth,
            pinOnly: _pinOnly,
          ));
        } else {
          // No live session, or cap 1: the live layer is replaced (cap 1 has
          // no suspended layer to evict, the pre-stack behavior exactly).
          replaced = live;
          _detachShared();
          _editor?.dispose();
          _frozen?.dispose();
          _cursorImage?.dispose();
        }
        _pinOnly = pinOnly;
        // Reseed BEFORE building the controller so the freshly-loaded styles
        // (incl. a reset that emptied the map) seed this capture's initial tool
        // style. The map instance is shared with the controller, so mutate it in
        // place. Null = store unavailable/error -> keep the current in-memory map.
        if (loadedStyles != null) {
          _toolStyles
            ..clear()
            ..addAll(loadedStyles);
        }
        // New capture LAYER: fresh dirty bits and a fresh op log instance
        // (the suspended layer keeps its own; fresh document = depth 1).
        _remoteDirty.clear();
        _localDirty = false;
        _opLog = SessionOpLog();
        _lastDepth = 1;
        setState(() {
          _frozen = frozen;
          _cursorImage = cursorImg;
          _cursorTopLeft = cursorTl;
          _editor = EditorController(toolStyles: _toolStyles);
          _display = d;
          // Bump so EditorCanvas gets a fresh State each capture (re-runs
          // initState with the correct isCursorDisplay + binds the new
          // controller). Without this, a display whose editor was NOT the one
          // that dismissed keeps its stale State -> stale _active -> no HUD until
          // the cursor crosses.
          _captureSeq++;
          _updateLayerCaption(replaced: replaced, evicted: evicted);
        });
        _attachShared(_editor!); // sync tool/style with the other displays
        // Frozen frame is built; reveal this display's window (no blank flash).
        _bridge.overlayReady();
        // Prefetch settings off the hot path: the read completes during the
        // user's crop interaction, so _onExport reads _capture synchronously.
        Settings.instance.loadCapture().then((c) {
          // setState so a fresh capture's EditorCanvas picks up settings that
          // affect interaction (e.g. rightClickExits); shutter/delivery read
          // _capture directly at export time.
          if (mounted) {
            setState(() => _capture = c);
            // Initialise this capture's cursor-layer toggle from the setting.
            _editor?.showCursor.value = c.captureCursor;
          }
        });
        // Prefetch the editor hotkey bindings the same way; EditorCanvas reads
        // widget.editorBindings live in _onKey, so the in-flight capture's State
        // (ValueKey already bumped) rebuilds with the loaded map.
        ShortcutStore(Settings.instance.store).all().then((b) {
          if (mounted) setState(() => _editorBindings = b);
        });
        // Loupe geometry (size + magnification); same per-capture prefetch.
        Settings.instance.loadLoupe().then((l) {
          if (mounted) setState(() => _loupe = l);
        });
        // HUD options (crosshair lines + marching-ants animation).
        Settings.instance.loadHud().then((h) {
          if (mounted) setState(() => _hud = h);
        });
      },
      onCaptureFailed: (reason, msg) {
        // A failed RE-trigger mid-session keeps the live session untouched;
        // only reset when nothing was on screen anyway.
        if (mounted && _editor == null) _resetState();
      },
      onActiveDisplay: (activeId, cursor) {
        if (mounted) _activeSignal.value = (id: activeId, cursor: cursor);
      },
      onEditorState: _applyRemoteEditorState,
      onSettingsOpen: () {
        if (mounted) setState(() => _settingsOpen = true);
      },
      onResume: () {
        if (mounted) setState(() => _settingsOpen = false);
        _reloadSettings();
        // Settings took keyboard focus; hand it back so tool shortcuts work
        // without a click (the native side re-keys the overlay window).
        _editor?.requestFocus();
      },
      onRecordSelectHotkey: _onRecordSelectHotkey,
    );
  }

  /// Hot-reload after a ⌘, Settings detour. RE-READS the settings that affect a
  /// LIVE capture: loupe geometry + the capture/output snapshot (`_capture`).
  /// Deliberately does NOT re-read in-session interaction state, because that
  /// would clobber what the user is doing: the per-capture mouse-pointer toggle
  /// (they may have flipped it this shot), the in-progress tool styles, and the
  /// current tool/selection. Those stay as the session left them.
  void _reloadSettings() {
    Settings.instance.loadLoupe().then((l) {
      if (mounted) setState(() => _loupe = l);
    });
    Settings.instance.loadHud().then((h) {
      if (mounted) setState(() => _hud = h);
    });
    Settings.instance.loadCapture().then((c) {
      if (mounted) setState(() => _capture = c);
    });
  }

  /// Loads the persisted per-tool styles, or null when the store is unavailable
  /// (e.g. a test environment with no platform binding) or errors — callers keep
  /// the current in-memory map in that case.
  Future<Map<ToolKind, DrawStyle>?> _loadToolStyles() async {
    try {
      return await ToolStyleStore(Settings.instance.store).load();
    } catch (_) {
      return null;
    }
  }

  /// A 1x1 fully-transparent image: the live-select session's base layer
  /// stand-in, so the shared editor (which requires a base image) runs over
  /// the live screen without painting anything.
  Future<ui.Image> _transparentStub() async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder); // nothing drawn = transparent
    final picture = recorder.endRecording();
    final img = await picture.toImage(1, 1);
    picture.dispose();
    return img;
  }

  // ---- record-select overlay (additive; never touches the live session) ----

  /// Arm (or re-arm) the record-select crop picker on THIS engine WITHOUT
  /// touching the live screenshot/pin session: it renders on top, the session
  /// (if any) renders presentation-only beneath. Sets `_rs = active`.
  Future<void> _beginRecordSelect(CapturedDisplay d) async {
    final stub = await _transparentStub();
    if (!mounted) {
      stub.dispose();
      return;
    }
    _recordStub?.dispose();
    _recordEditor?.dispose();
    _recordOverrides?.dispose();
    final overrides = RecordOverrides(
        showCursor: true,
        systemAudio: false,
        microphone: false,
        hevc: false,
        gif: false,
        fps: 30,
        maxDuration: 0);
    _recordOverrides = overrides;
    Settings.instance.loadRecording().then((r) {
      if (!mounted || _recordOverrides != overrides) return;
      overrides.showCursor.value = r.showCursor;
      overrides.systemAudio.value = r.systemAudio;
      overrides.microphone.value = r.microphone;
      overrides.hevc.value = r.hevc;
      overrides.gif.value = r.isGif;
      overrides.fps.value = r.fps;
      overrides.maxDuration.value = r.maxDuration;
    });
    setState(() {
      _recordDisplay = d;
      _lastKnownDisplay = d;
      _recordStub = stub;
      _recordEditor = EditorController(toolStyles: {});
      _rs = RecordSelectState.active;
      _captureSeq++;
    });
    _bridge.overlayReady(); // reveal this engine's window (no blank flash)
    Settings.instance.loadLoupe().then((l) {
      if (mounted) setState(() => _loupe = l);
    });
    Settings.instance.loadHud().then((h) {
      if (mounted) setState(() => _hud = h);
    });
  }

  /// Tear down the RS overlay state (confirm / cancel). Does NOT touch the live
  /// session, the layer stack, or broadcast. If a session REMAINS beneath, bump
  /// the capture sequence so its EditorCanvas REMOUNTS fresh: while the picker
  /// was on top the session ran presentation-only (no chrome, input ignored, and
  /// the native cursor was hidden by the picker's crop tool). A remount re-runs
  /// initState with presentationOnly == false, so the session returns to the
  /// active/interactive state — toolbar, crosshair, loupe, and cursor management
  /// all re-establish (same idea as `_restoreSuspended`'s `_captureSeq++`).
  void _disposeRecordSelect() {
    _recordEditor?.dispose();
    _recordStub?.dispose();
    _recordEditor = null;
    _recordStub = null;
    _recordDisplay = null;
    _rs = RecordSelectState.none;
    if (_display != null) _captureSeq++;
  }

  /// active -> suspended: a freeze layer was taken on top. Keep the per-take
  /// overrides; drop the live crop editor/stub (rebuilt fresh on resurface).
  void _suspendRecordSelect() {
    _recordEditor?.dispose();
    _recordStub?.dispose();
    _recordEditor = null;
    _recordStub = null;
    _recordDisplay = null;
    _rs = RecordSelectState.suspended;
  }

  /// suspended -> active again (record hotkey, or auto-restore on freeze drain).
  /// The live session (if any) stays in the slot, rendered presentation-only.
  Future<void> _resurfaceRecordSelect(CapturedDisplay d) async {
    if (_rs != RecordSelectState.suspended) return;
    await _beginRecordSelect(d);
  }

  /// Empty the live session slot (dispose editor/frozen/cursor + reset dirty/op
  /// state) WITHOUT touching RS, the layer stack, or the native window. Used
  /// when a freeze layer is resolved but a suspended record-select must surface
  /// beneath it (the overlay window stays up for RS).
  void _clearLiveSession() {
    _lastKnownDisplay = _display ?? _lastKnownDisplay;
    _detachShared();
    _editor?.dispose();
    _frozen?.dispose();
    _cursorImage?.dispose();
    _remoteDirty.clear();
    _localDirty = false;
    _opLog = SessionOpLog();
    _lastDepth = 1;
    _display = null;
    _editor = null;
    _frozen = null;
    _cursorImage = null;
    _cursorTopLeft = null;
  }

  /// Record-select confirm: start recording over whatever is beneath, then drop
  /// the picker on every engine. A session beneath stays up (recorded as
  /// content); no session -> the overlay dismisses (records the live desktop).
  Future<void> _onRecordConfirm(Rect? selectionLogical, SnapWindow? window) async {
    final d = _recordDisplay;
    if (d == null) return;
    final o = _recordOverrides;
    final hadSession = _display != null;
    _bridge.broadcastEditorState({'recordSelectEnd': true});
    setState(_disposeRecordSelect);
    if (!hadSession) _bridge.dismissOverlay(); // nothing beneath -> hide window
    try {
      await _bridge.recordSelection(
        displayId: d.displayId,
        rect: selectionLogical,
        title: window?.title,
        app: window?.app,
        showsCursor: o?.showCursor.value,
        systemAudio: o?.systemAudio.value,
        microphone: o?.microphone.value,
        hevc: o?.hevc.value,
        gif: o?.gif.value,
        fps: o?.fps.value,
        maxDuration: o?.maxDuration.value,
      );
    } catch (_) {}
  }

  /// Record-select cancel (Esc / right-click on the picker). Drops the picker on
  /// every engine and tells the record controller; the session beneath (if any)
  /// stays.
  Future<void> _onRecordSelectCancel() async {
    final d = _recordDisplay;
    final hadSession = _display != null;
    _bridge.broadcastEditorState({'recordSelectEnd': true});
    setState(_disposeRecordSelect);
    if (!hadSession) _bridge.dismissOverlay();
    if (d != null) {
      try {
        await _bridge.recordSelection(displayId: d.displayId, cancelled: true);
      } catch (_) {}
    }
  }

  /// Record hotkey while a record-select exists: resurface a suspended picker
  /// (session beneath stays), or cancel a foreground one. Relayed from the
  /// control engine to EVERY overlay engine, so each handles its OWN RS locally
  /// — no peer broadcast. The redundant cancelled-relay to the record controller
  /// (one per engine) is idempotent (`_onSelection` just resets the phase).
  void _onRecordSelectHotkey() {
    if (_rs == RecordSelectState.active) {
      final d = _recordDisplay;
      final hadSession = _display != null;
      setState(_disposeRecordSelect);
      if (!hadSession) _bridge.hideOverlayWindow();
      if (d != null) {
        _bridge
            .recordSelection(displayId: d.displayId, cancelled: true)
            .catchError((_) {});
      }
    } else if (_rs == RecordSelectState.suspended) {
      final d = _display ?? _lastKnownDisplay;
      if (d != null) _resurfaceRecordSelect(d);
    }
  }

  void _resetState() {
    _detachShared();
    _remoteDirty.clear();
    _localDirty = false;
    _opLog.clear();
    _lastDepth = 1;
    _editor?.dispose();
    _frozen?.dispose();
    _cursorImage?.dispose();
    // Whole-session teardown: every suspended layer goes too.
    for (final l in _layers.drain()) {
      l.disposeAll();
    }
    _layerNoticeTimer?.cancel();
    _disposeRecordSelect(); // whole-session teardown drops any record-select too
    setState(() {
      _display = null;
      _editor = null;
      _frozen = null;
      _cursorImage = null;
      _layerCaption = null;
      _layerAccent = false;
    });
  }

  // ---- cross-display tool/style sync -------------------------------------

  void _attachShared(EditorController e) {
    e.tool.addListener(_broadcastEditorState);
    e.style.addListener(_broadcastEditorState);
    e.style.addListener(_schedulePersist);
    e.stampImage.addListener(_broadcastStamp);
    e.document.addListener(_broadcastLocalDirty);
    e.document.addListener(_trackLocalOp);
    e.selectedIndex.addListener(_broadcastSelection);
    e.undoOverride = _globalUndo;
    e.redoOverride = _globalRedo;
  }

  void _detachShared() {
    _editor?.tool.removeListener(_broadcastEditorState);
    _editor?.style.removeListener(_broadcastEditorState);
    _editor?.style.removeListener(_schedulePersist);
    _editor?.stampImage.removeListener(_broadcastStamp);
    _editor?.document.removeListener(_broadcastLocalDirty);
    _editor?.document.removeListener(_trackLocalOp);
    _editor?.selectedIndex.removeListener(_broadcastSelection);
    _editor?.undoOverride = null;
    _editor?.redoOverride = null;
  }

  /// Session op-log bookkeeping for THIS display's document: an unguarded
  /// history-depth +1 is a user-committed op — stamp it with the next session
  /// clock and broadcast. Protocol-driven changes only resync the depth.
  void _trackLocalOp() {
    final e = _editor;
    final d = _display;
    if (e == null || d == null) return;
    final depth = e.document.value.historyDepth;
    final grew = depth == _lastDepth + 1;
    _lastDepth = depth;
    if (_applyingProtocol || !grew) return;
    final clock = _opLog.nextClock();
    _opLog.recordOp(clock, d.displayId);
    _bridge.broadcastEditorState({'op': clock, 'display': d.displayId});
  }

  /// ⌘Z routed session-wide (EditorController.undoOverride): target the
  /// SESSION's latest op; every replica moves it, the owning display
  /// (possibly not this one) pops its document.
  void _globalUndo() {
    final t = _opLog.undoTarget;
    if (t == null) return;
    _performUndo(t.clock, t.display);
    _bridge.broadcastEditorState({'undoOp': t.clock, 'display': t.display});
  }

  void _globalRedo() {
    final t = _opLog.redoTarget;
    if (t == null) return;
    _performRedo(t.clock, t.display);
    _bridge.broadcastEditorState({'redoOp': t.clock, 'display': t.display});
  }

  void _performUndo(int clock, int display) {
    if (!_opLog.markUndone(clock, display)) return;
    if (display != _display?.displayId) return;
    final e = _editor;
    if (e == null) return;
    _applyingProtocol = true;
    e.undoLocal();
    e.selectedIndex.value = null; // indices shifted under the selection
    _applyingProtocol = false;
  }

  void _performRedo(int clock, int display) {
    if (!_opLog.markRedone(clock, display)) return;
    if (display != _display?.displayId) return;
    final e = _editor;
    if (e == null) return;
    _applyingProtocol = true;
    e.redoLocal();
    e.selectedIndex.value = null;
    _applyingProtocol = false;
  }

  /// Session-global single selection: claiming a selection here clears it on
  /// every other display. Broadcast only on the transition INTO a selection —
  /// deselects need no message.
  void _broadcastSelection() {
    if (_applyingRemoteSel) return;
    final e = _editor;
    final d = _display;
    if (e == null || d == null) return;
    if (e.selectedIndex.value == null) return;
    _bridge.broadcastEditorState({'selectedOn': d.displayId});
  }

  /// Tell the other displays whether THIS display holds unsaved annotations,
  /// on empty<->non-empty transitions only — their cancel confirm must cover
  /// work they cannot see. Sent immediately (not throttled): transitions are
  /// rare and the bit must not lag behind a fast draw-then-Esc.
  void _broadcastLocalDirty() {
    final e = _editor;
    final d = _display;
    if (e == null || d == null) return;
    final dirty = e.document.value.drawables.isNotEmpty;
    if (dirty == _localDirty) return;
    _localDirty = dirty;
    _bridge.broadcastEditorState({'dirty': dirty, 'display': d.displayId});
  }

  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 400), () {
      ToolStyleStore(Settings.instance.store).save(Map.of(_toolStyles));
    });
  }

  @override
  void dispose() {
    _frames.detach();
    _broadcastRateTimer?.cancel();
    _broadcastTimer?.cancel();
    _persistTimer?.cancel();
    _layerNoticeTimer?.cancel();
    _detachShared();
    _editor?.dispose();
    _frozen?.dispose();
    _cursorImage?.dispose();
    _recordEditor?.dispose();
    _recordStub?.dispose();
    _recordOverrides?.dispose();
    for (final l in _layers.drain()) {
      l.disposeAll();
    }
    _activeSignal.dispose();
    super.dispose();
  }

  /// Push the active tool + style to the other displays (skipped while applying
  /// a remote update, so the two engines don't ping-pong). Throttled: a slider
  /// drag fires the style listener per tick (measured 40-58/sec), so sends are
  /// leading+trailing coalesced to <=10/sec — a discrete change (tool switch,
  /// single pick) still syncs instantly, and a drag's END state always lands
  /// via the trailing send. The receiving display only mirrors the option bar
  /// and drawing defaults, so a <=100ms lag is invisible.
  void _broadcastEditorState() {
    if (_applyingRemote) return;
    if (_editor == null) return;
    if (_broadcastTimer != null) {
      _broadcastDirty = true;
      return;
    }
    _sendEditorState();
    _startBroadcastQuiet();
  }

  void _startBroadcastQuiet() {
    _broadcastTimer = Timer(const Duration(milliseconds: 100), () {
      _broadcastTimer = null;
      if (!_broadcastDirty) return;
      _broadcastDirty = false;
      if (_editor == null) return; // capture ended while coalescing
      _sendEditorState();
      _startBroadcastQuiet();
    });
  }

  void _sendEditorState() {
    final e = _editor;
    if (e == null) return;
    // Send the full DrawStyle JSON (same shape as persistence) so EVERY style
    // field stays in sync — incl. fontFamily and the highlighter texture — and a
    // future field can't silently drop out of the cross-display broadcast.
    _bridge.broadcastEditorState({
      'tool': e.tool.value.index,
      ...e.style.value.toJson(),
    });
    // M6: count actual sends per 1s window while they flow — the mark itself
    // is at most one channel call per second.
    _broadcastCount++;
    _broadcastRateTimer ??= Timer(const Duration(seconds: 1), () {
      _perfSink('broadcastRate n=$_broadcastCount');
      _broadcastCount = 0;
      _broadcastRateTimer = null;
    });
  }

  /// Push the chosen stamp image to the other displays as raw bytes (each decodes
  /// its own ui.Image — images cannot cross Flutter engines). One-shot on pick,
  /// kept OFF the per-change tool/style broadcast so a frequent style edit never
  /// re-sends the image. Uint8List rides the StandardMethodCodec channel as
  /// binary (no base64); the native side relays the args verbatim.
  void _broadcastStamp() {
    if (_applyingRemote) return;
    final bytes = _editor?.stampBytes;
    if (bytes == null) return;
    _bridge.broadcastEditorState({'stampBytes': bytes});
  }

  /// Decode a stamp broadcast from another display and set it locally (guarded so
  /// setting it does not bounce the broadcast back).
  Future<void> _applyRemoteStamp(Uint8List bytes) async {
    final e = _editor;
    if (e == null) return;
    final ui.Image img;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      img = (await codec.getNextFrame()).image;
    } catch (_) {
      return;
    }
    if (!mounted || _editor != e) return;
    _applyingRemote = true;
    e.setStamp(img, bytes);
    _applyingRemote = false;
  }

  /// Mirror a tool/style change received from another display onto this editor.
  void _applyRemoteEditorState(Map<String, dynamic> state) {
    // Layer protocol first: these must work even with a null editor (e.g. an
    // engine that already hid its window for a layer it has no frame for).
    if (state['layerPop'] == true) {
      _restoreSuspended();
      return;
    }
    if (state['sessionEnded'] == true) {
      _resetState();
      return;
    }
    // Record-select protocol (null-editor-tolerant): a picker can be live on an
    // engine whose display has no freeze session.
    if (state['recordSelectEnd'] == true) {
      if (_rs != RecordSelectState.none) {
        final hadSession = _display != null;
        setState(_disposeRecordSelect);
        if (!hadSession) _bridge.hideOverlayWindow();
      }
      return;
    }
    if (state['recordSelectRestore'] == true) {
      // Active engine resolved its last freeze layer with a picker waiting
      // beneath: clear this engine's just-resolved freeze session and surface
      // the picker. (Suspend + hotkey-resurface are global per-engine events
      // and need no peer message; only this freeze-resolution path does.)
      if (_rs == RecordSelectState.suspended) {
        final d = _display ?? _lastKnownDisplay;
        if (d != null) {
          _clearLiveSession();
          _resurfaceRecordSelect(d);
        }
      }
      return;
    }
    final e = _editor;
    if (e == null) return;
    // A dirty broadcast carries only the sender's unsaved-annotations bit (no
    // tool/style) — track it for the cancel confirm and stop here.
    final dirty = state['dirty'];
    if (dirty is bool) {
      final from = (state['display'] as num?)?.toInt();
      if (from != null) {
        dirty ? _remoteDirty.add(from) : _remoteDirty.remove(from);
      }
      return;
    }
    // Session op-log traffic: a committed op / undo / redo on another display.
    final op = state['op'];
    if (op is int) {
      final from = (state['display'] as num?)?.toInt();
      if (from != null) {
        _opLog.recordOp(op, from);
        // A new session op invalidates this document's own redo tail too.
        final doc = e.document.value;
        if (doc.canRedo) {
          _applyingProtocol = true;
          e.document.value = doc.clearedRedo();
          _applyingProtocol = false;
        }
      }
      return;
    }
    final undoOp = state['undoOp'];
    if (undoOp is int) {
      final from = (state['display'] as num?)?.toInt();
      if (from != null) _performUndo(undoOp, from);
      return;
    }
    final redoOp = state['redoOp'];
    if (redoOp is int) {
      final from = (state['display'] as num?)?.toInt();
      if (from != null) _performRedo(redoOp, from);
      return;
    }
    // Another display claimed the session-single annotation selection.
    if (state['selectedOn'] is num) {
      if (e.selectedIndex.value != null) {
        _applyingRemoteSel = true;
        e.selectedIndex.value = null;
        _applyingRemoteSel = false;
      }
      return;
    }
    // A stamp broadcast carries only the image bytes (no tool/style); decode and
    // apply it on its own async path.
    final stampBytes = state['stampBytes'];
    if (stampBytes is Uint8List) {
      _applyRemoteStamp(stampBytes);
      return;
    }
    _applyingRemote = true;
    final t = ToolKind.values[state['tool'] as int];
    final s = DrawStyle.fromJson(state); // tolerant; ignores the extra 'tool' key
    e.tool.value = t;
    e.phase.value = t == ToolKind.crop
        ? EditorPhase.crop
        : EditorPhase.annotate;
    e.selectedIndex.value = null;
    e.style.value = s;
    e.toolStyles[t] = s; // keep per-tool memory in sync too
    _applyingRemote = false;
  }

  void _dismiss() {
    _resetState();
    _bridge.dismissOverlay();
  }

  /// Recompute the toolbar layer caption (the single-line bar below the tool
  /// row). Depth >= 2 shows "Layers: N/cap". The accent notices (3 s) keep
  /// the full-stack policy visible: [replaced] = cap 1 restarted the capture;
  /// [evicted] = the OLDEST suspended layer was dropped to keep the most
  /// recent ones (cap >= 2).
  void _updateLayerCaption({bool replaced = false, bool evicted = false}) {
    _layerNoticeTimer?.cancel();
    final depth = _layers.suspendedCount + 1;
    if (replaced || evicted) {
      _layerCaption = replaced
          ? appL10n.layerReplacedNotice(depth, _layers.capacity)
          : appL10n.oldestLayerDroppedNotice(depth, _layers.capacity);
      _layerAccent = true;
      _layerNoticeTimer = Timer(const Duration(seconds: 3), () {
        if (!mounted) return;
        setState(() {
          _layerAccent = false;
          _layerCaption = _layers.suspendedCount > 0
              ? appL10n.layersCaption(
                  _layers.suspendedCount + 1, _layers.capacity)
              : null;
        });
      });
    } else {
      _layerCaption = _layers.suspendedCount > 0
          ? appL10n.layersCaption(depth, _layers.capacity)
          : null;
      _layerAccent = false;
    }
  }

  /// End the CURRENT layer: pop back to the suspended layer below when one
  /// exists (broadcasting so every engine pops in step), else end the whole
  /// session (broadcast + native dismiss, the pre-stack behavior).
  void _endTopLayer() {
    if (_layers.suspendedCount > 0) {
      _bridge.broadcastEditorState({'layerPop': true});
      _restoreSuspended();
    } else if (_rs == RecordSelectState.suspended) {
      // Last freeze layer resolved, but a record-select waits beneath it:
      // surface the picker again instead of ending the session. The overlay
      // window stays up; the just-resolved freeze session is cleared.
      _bridge.broadcastEditorState({'recordSelectRestore': true});
      final d = _display ?? _lastKnownDisplay;
      _clearLiveSession();
      if (d != null) {
        _resurfaceRecordSelect(d);
      } else {
        _dismiss();
      }
    } else {
      _bridge.broadcastEditorState({'sessionEnded': true});
      _dismiss();
    }
  }

  /// Discard the live layer's state and resume the top suspended layer. When
  /// this engine has nothing suspended (its display joined mid-session), hide
  /// just this window and go idle; the session continues elsewhere.
  void _restoreSuspended() {
    final l = _layers.resume();
    _detachShared();
    _editor?.dispose();
    _frozen?.dispose();
    _cursorImage?.dispose();
    if (l == null) {
      _remoteDirty.clear();
      _localDirty = false;
      _opLog = SessionOpLog();
      _lastDepth = 1;
      setState(() {
        _display = null;
        _editor = null;
        _frozen = null;
        _cursorImage = null;
        _layerCaption = null;
        _layerAccent = false;
      });
      _bridge.hideOverlayWindow();
      return;
    }
    _opLog = l.opLog;
    _lastDepth = l.lastDepth;
    _localDirty = l.localDirty;
    _remoteDirty
      ..clear()
      ..addAll(l.remoteDirty);
    _pinOnly = l.pinOnly;
    setState(() {
      _display = l.display;
      _frozen = l.frozen;
      _cursorImage = l.cursorImage;
      _cursorTopLeft = l.cursorTopLeft;
      _editor = l.editor;
      _captureSeq++; // remount EditorCanvas on the restored controller
      _updateLayerCaption();
    });
    _attachShared(l.editor);
  }

  /// Cancel path (Esc / right-click on empty space). Confirms first when there are
  /// unsaved annotations and the setting is on, so an accidental exit can't waste
  /// them; export (success) never routes here. Covers BOTH this display's
  /// document and the other displays' broadcast dirty bits — dismissing here
  /// discards the whole session, including work drawn on a screen this engine
  /// cannot see.
  Future<void> _onCancelRequested() async {
    if (_confirmingExit) return;
    final editor = _editor;
    final hasAnnotations = (editor != null &&
            editor.document.value.drawables.isNotEmpty) ||
        _remoteDirty.isNotEmpty;
    if (hasAnnotations && await Settings.instance.getConfirmOnExit()) {
      final ctx = _navigatorKey.currentContext;
      if (ctx != null && ctx.mounted) {
        _confirmingExit = true;
        final layered = _layers.suspendedCount > 0;
        final ok = await showDiscardConfirm(
          ctx,
          title: layered
              ? appL10n.overlayDiscardLayerTitle
              : appL10n.overlayDiscardCaptureTitle,
          message: layered
              ? appL10n.overlayDiscardLayerMessage
              : appL10n.overlayDiscardCaptureMessage,
        );
        _confirmingExit = false;
        if (!ok) {
          // Staying in the capture: the dialog took keyboard focus; hand it back
          // to the editor so tool shortcuts work without a manual click.
          editor?.requestFocus();
          return;
        }
      }
    }
    _endTopLayer();
  }

  Future<void> _onExport(Rect? selectionLogical, SnapWindow? window) async {
    final d = _display;
    final frozen = _frozen;
    final editor = _editor;
    if (d == null || frozen == null || editor == null) {
      _dismiss();
      return;
    }
    // Snapshot the (immutable) inputs, then HIDE the overlay IMMEDIATELY so the
    // user isn't staring at the frozen frame while we composite / encode /
    // deliver. This export takes over the frozen image's lifecycle (disposes it
    // when done), so null _frozen first to keep _dismiss/_resetState from
    // disposing it out from under the background work. The shutter sound is the
    // last delivery leg, so it lands on completion.
    final cap = _capture; // snapshot prefetched at capture (off the hot path)
    // Record this capture's final rect so "Capture Last Region" can repeat it.
    // A snap arrives as selectionLogical == window.rect (a fixed rect), so it is
    // recorded as a fixed region, not a live window reference.
    LastRegionStore(Settings.instance.store).save(LastRegion(
      displayId: d.displayId,
      rect: resolveRecordedRect(
          selectionLogical, window?.rect, d.width, d.height),
    ));
    if (cap.shutterSound) {
      playShutter(); // shutter at the instant of capture (fire-and-forget)
    }
    final drawables = editor.document.value.drawables;
    // Classify the scenario so decoration can be gated per capture kind. A snap
    // commits the window's OWN rect as the selection; a freehand crop carries its
    // own dragged selection (the window, if any, only names the file); neither =>
    // the whole annotated display (never decorated).
    final kind = overlayCaptureKind(
      selectionIsWindowRect:
          window != null && selectionLogical == window.rect,
      hasSelection: selectionLogical != null,
    );
    // Snapshot the toggleable cursor layer; this export takes over its disposal
    // so a following capture / dismiss can't dispose it mid-composite.
    final cursorImg = _cursorImage;
    _cursorImage = null;
    final cursorOn = editor.showCursor.value && cursorImg != null;
    final cursorTopLeftNative = (cursorOn && _cursorTopLeft != null)
        ? _cursorTopLeft! * d.scaleFactor
        : null;
    // Snapshot THIS layer's pin flag: the pop below restores the layer
    // underneath, which overwrites _pinOnly before the export reads it.
    final pinOnly = _pinOnly;
    _frozen = null;
    // Pop back to the layer below (or end the session when this was the only
    // one) IMMEDIATELY; the export composites in the background on its own
    // snapshots (frozen/cursor ownership was transferred above).
    _endTopLayer();
    // For a window snap, capture the window's real alpha so the export takes the
    // window's rounded-corner silhouette (frozen pixels + live alpha mask). The
    // window can't move during the freeze, so the mask aligns with the crop.
    // showsCursor:false — the cursor must NOT pollute the window-shape mask.
    // Best effort — any failure falls back to the rectangular crop.
    ui.Image? windowMask;
    if (kind == CaptureKind.overlaySnap && window?.windowId != null) {
      try {
        final wi =
            await _bridge.captureWindowImage(window!.windowId!, showsCursor: false);
        if (wi != null) {
          // Raw BGRA8888 (premultiplied, sRGB) -> ui.Image without a PNG codec,
          // same as the freeze path. Only the alpha is used (dstIn mask).
          final completer = Completer<ui.Image>();
          ui.decodeImageFromPixels(
            wi.rawBytes, wi.width, wi.height, ui.PixelFormat.bgra8888,
            completer.complete, rowBytes: wi.rowBytes,
          );
          windowMask = await completer.future;
        }
      } catch (_) {
        /* fall back to a rectangular crop */
      }
    }
    try {
      final result = await exportAnnotated(
        display: d,
        frozenImage: frozen,
        drawables: drawables,
        selectionLogical: selectionLogical,
        cap: cap,
        kind: kind,
        windowMask: windowMask,
        cursorImage: cursorOn ? cursorImg : null,
        cursorTopLeftNative: cursorTopLeftNative,
        windowTitle: window?.title,
        appName: window?.app,
        // ⌘⌥5 capture-to-pin: this LAYER runs ONLY the pin action (snapshot
        // taken before the pop, see above).
        flowOverride: pinOnly ? const {FlowAction.pin} : null,
      );
      // Success = every ENABLED leg succeeded (a disabled leg is not a failure).
      // On success play the completion chime (if enabled); on a real failure the
      // overlay is already gone, so surface it via a native alert.
      final eff = pinOnly ? const {FlowAction.pin} : cap.flow;
      final ok =
          (!eff.contains(FlowAction.save) || result.savedOk) &&
          (!eff.contains(FlowAction.copy) || result.copiedToClipboard) &&
          !result.extraErrors.containsKey('pin');
      if (ok) {
        if (cap.completionSound) playComplete();
      } else {
        _bridge.showError(
            pinOnly ? appL10n.overlayPinFailed : _summary(result, cap));
      }
    } catch (e) {
      _bridge.showError(appL10n.overlayCaptureFailedError('$e'));
    } finally {
      windowMask?.dispose();
      cursorImg?.dispose();
      frozen.dispose();
    }
  }

  String _summary(FlowResult r, CaptureSettings cap) {
    final saveFailed = cap.flow.contains(FlowAction.save) && !r.savedOk;
    final clipFailed = cap.flow.contains(FlowAction.copy) && !r.copiedToClipboard;
    if (saveFailed && clipFailed) return appL10n.overlayFailedNotSavedOrCopied;
    if (saveFailed) return appL10n.overlayFailedSave;
    if (clipFailed) return appL10n.overlayFailedClipboard;
    return appL10n.overlayCaptureFailedGeneric;
  }

  @override
  Widget build(BuildContext context) {
    final d = _display;
    final frozen = _frozen;
    final editor = _editor;
    final rsActive = _rs == RecordSelectState.active;
    final hasSession = d != null && frozen != null && editor != null;
    final showAnything = hasSession || rsActive;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      locale: appLocaleOverride,
      localeListResolutionCallback: resolveAppLocale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      // Both themes so Material defaults (e.g. toolbar tooltips) follow the
      // system appearance; our chrome resolves its own palettes regardless.
      theme: ThemeData(
        scaffoldBackgroundColor: Colors.transparent,
        tooltipTheme: glimprTooltipTheme(Brightness.light),
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.transparent,
        tooltipTheme: glimprTooltipTheme(Brightness.dark),
      ),
      home: !showAnything
          // Idle: fully transparent until a capture sets the frozen frame.
          ? const SizedBox.shrink()
          : Stack(
              fit: StackFit.expand,
              children: [
                // Bottom: the live screenshot/pin session. While a record-select
                // is foreground above it the session renders PRESENTATION-ONLY
                // (no chrome, ignores pointer) so the picker on top owns input.
                if (hasSession)
                  IgnorePointer(
                    ignoring: rsActive,
                    child: EditorCanvas(
                      key: ValueKey('session-$_captureSeq'),
                      display: d,
                      frozenImage: frozen,
                      controller: editor,
                      onExport: _onExport,
                      onCancel: _onCancelRequested,
                      activeSignal: _activeSignal,
                      rightClickExits: _capture.rightClickExits,
                      editorBindings: _editorBindings,
                      loupe: _loupe,
                      hud: _hud,
                      cursorImage: _cursorImage,
                      cursorTopLeft: _cursorTopLeft,
                      pinMode: _pinOnly,
                      presentationOnly: rsActive,
                      layerCaption: _layerCaption,
                      layerAccent: _layerAccent,
                    ),
                  ),
                // Top: the record-select picker. A light veil keeps every window
                // pixel non-zero alpha (WindowServer click-through guard) and
                // dims whatever is beneath (live desktop or the frozen session).
                if (rsActive) ...[
                  const ColoredBox(color: GlimprTokens.scrim),
                  EditorCanvas(
                    key: ValueKey('rs-$_captureSeq'),
                    display: _recordDisplay!,
                    frozenImage: _recordStub!,
                    controller: _recordEditor!,
                    onExport: _onRecordConfirm,
                    onCancel: _onRecordSelectCancel,
                    activeSignal: _activeSignal,
                    rightClickExits: _capture.rightClickExits,
                    editorBindings: _editorBindings,
                    loupe: _loupe,
                    hud: _hud,
                    recordMode: true,
                    liveLoupeSample: _bridge.loupeSample,
                    recordOverrides: _recordOverrides,
                  ),
                ],
                // Dim + lock the freeze while a ⌘, Settings detour is open.
                if (_settingsOpen) const SettingsMask(),
              ],
            ),
    );
  }
}

/// One suspended capture layer: everything needed to resume the session
/// exactly as it was. The controller is detached from the cross-display
/// listeners while suspended; images are owned by this frame until resumed
/// or disposed.
class _SessionLayer {
  _SessionLayer({
    required this.display,
    required this.frozen,
    required this.cursorImage,
    required this.cursorTopLeft,
    required this.editor,
    required this.opLog,
    required this.remoteDirty,
    required this.localDirty,
    required this.lastDepth,
    required this.pinOnly,
  });
  final CapturedDisplay display;
  final ui.Image frozen;
  final ui.Image? cursorImage;
  final Offset? cursorTopLeft;
  final EditorController editor;
  final SessionOpLog opLog;
  final Set<int> remoteDirty;
  final bool localDirty;
  final int lastDepth;
  final bool pinOnly;

  void disposeAll() {
    editor.dispose();
    frozen.dispose();
    cursorImage?.dispose();
  }
}
