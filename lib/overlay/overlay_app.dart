import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../capture/capture_bridge.dart';
import '../capture/capture_kind.dart';
import '../capture/captured_display.dart';
import '../capture/last_region.dart';
import '../editor/draw_style.dart';
import '../editor/editor_controller.dart';
import '../editor/hud_config.dart';
import '../editor/loupe_config.dart';
import '../editor/tool_style_store.dart';
import '../output/flow.dart';
import '../output/sounds.dart';
import '../settings/settings.dart';
import '../settings/settings_mask.dart';
import '../theme/confirm_dialog.dart';
import '../shortcuts/hotkey_binding.dart';
import '../shortcuts/shortcut_actions.dart';
import '../shortcuts/shortcut_store.dart';
import 'editor_canvas.dart';
import 'export.dart';

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
  // The ⌘⌥7 "capture to pin" mode: this session's confirm runs ONLY the pin
  // action instead of the configured after-capture flow.
  bool _pinOnly = false;
  // Debounce timer for persisting _toolStyles to the store.
  Timer? _persistTimer;

  @override
  void initState() {
    super.initState();
    _bridge.registerOverlayHandlers(
      onCaptureReady: (d, pinOnly) async {
        _pinOnly = pinOnly;
        // Reseed per-tool styles from disk on EVERY capture so a Settings
        // "Reset all tool styles" (or an edit made on another engine) takes
        // effect on THIS capture — not only after a restart. Kicked off now and
        // awaited just before the controller is built, so its latency hides
        // behind the image decode below (no added reveal delay).
        final stylesFuture = _loadToolStyles();
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
        _detachShared();
        _editor?.dispose();
        _frozen?.dispose();
        _cursorImage?.dispose();
        // Reseed BEFORE building the controller so the freshly-loaded styles
        // (incl. a reset that emptied the map) seed this capture's initial tool
        // style. The map instance is shared with the controller, so mutate it in
        // place. Null = store unavailable/error -> keep the current in-memory map.
        if (loadedStyles != null) {
          _toolStyles
            ..clear()
            ..addAll(loadedStyles);
        }
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
        if (mounted) _resetState();
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

  void _resetState() {
    _detachShared();
    _editor?.dispose();
    _frozen?.dispose();
    _cursorImage?.dispose();
    setState(() {
      _display = null;
      _editor = null;
      _frozen = null;
      _cursorImage = null;
    });
  }

  // ---- cross-display tool/style sync -------------------------------------

  void _attachShared(EditorController e) {
    e.tool.addListener(_broadcastEditorState);
    e.style.addListener(_broadcastEditorState);
    e.style.addListener(_schedulePersist);
    e.stampImage.addListener(_broadcastStamp);
  }

  void _detachShared() {
    _editor?.tool.removeListener(_broadcastEditorState);
    _editor?.style.removeListener(_broadcastEditorState);
    _editor?.style.removeListener(_schedulePersist);
    _editor?.stampImage.removeListener(_broadcastStamp);
  }

  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 400), () {
      ToolStyleStore(Settings.instance.store).save(Map.of(_toolStyles));
    });
  }

  @override
  void dispose() {
    _persistTimer?.cancel();
    _detachShared();
    _editor?.dispose();
    _frozen?.dispose();
    _cursorImage?.dispose();
    _activeSignal.dispose();
    super.dispose();
  }

  /// Push the active tool + style to the other displays (skipped while applying
  /// a remote update, so the two engines don't ping-pong).
  void _broadcastEditorState() {
    if (_applyingRemote) return;
    final e = _editor;
    if (e == null) return;
    // Send the full DrawStyle JSON (same shape as persistence) so EVERY style
    // field stays in sync — incl. fontFamily and the highlighter texture — and a
    // future field can't silently drop out of the cross-display broadcast.
    _bridge.broadcastEditorState({
      'tool': e.tool.value.index,
      ...e.style.value.toJson(),
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
    final e = _editor;
    if (e == null) return;
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

  /// Cancel path (Esc / right-click on empty space). Confirms first when there are
  /// unsaved annotations and the setting is on, so an accidental exit can't waste
  /// them; export (success) never routes here.
  Future<void> _onCancelRequested() async {
    if (_confirmingExit) return;
    final editor = _editor;
    final hasAnnotations =
        editor != null && editor.document.value.drawables.isNotEmpty;
    if (hasAnnotations && await Settings.instance.getConfirmOnExit()) {
      final ctx = _navigatorKey.currentContext;
      if (ctx != null && ctx.mounted) {
        _confirmingExit = true;
        final ok = await showDiscardConfirm(
          ctx,
          title: 'Discard capture?',
          message: 'You have unsaved annotations on this capture. '
              'Discard them and exit?',
        );
        _confirmingExit = false;
        if (!ok) {
          // Staying in the capture: the dialog took keyboard focus; hand it back
          // to the editor so tool shortcuts work without a manual click.
          editor.requestFocus();
          return;
        }
      }
    }
    _dismiss();
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
    _frozen = null;
    _dismiss();
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
          final codec = await ui.instantiateImageCodec(wi.pngBytes);
          windowMask = (await codec.getNextFrame()).image;
          codec.dispose();
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
        // ⌘⌥7 capture-to-pin: this session runs ONLY the pin action.
        flowOverride: _pinOnly ? const {FlowAction.pin} : null,
      );
      // Success = every ENABLED leg succeeded (a disabled leg is not a failure).
      // On success play the completion chime (if enabled); on a real failure the
      // overlay is already gone, so surface it via a native alert.
      final eff = _pinOnly ? const {FlowAction.pin} : cap.flow;
      final ok =
          (!eff.contains(FlowAction.save) || result.savedOk) &&
          (!eff.contains(FlowAction.copy) || result.copiedToClipboard) &&
          !result.extraErrors.containsKey('pin');
      if (ok) {
        if (cap.completionSound) playComplete();
      } else {
        _bridge.showError(_pinOnly ? 'Pin failed' : _summary(result, cap));
      }
    } catch (e) {
      _bridge.showError('Capture failed: $e');
    } finally {
      windowMask?.dispose();
      cursorImg?.dispose();
      frozen.dispose();
    }
  }

  String _summary(FlowResult r, CaptureSettings cap) {
    final saveFailed = cap.flow.contains(FlowAction.save) && !r.savedOk;
    final clipFailed = cap.flow.contains(FlowAction.copy) && !r.copiedToClipboard;
    if (saveFailed && clipFailed) return 'Capture failed — not saved or copied';
    if (saveFailed) return 'Copied — file save failed';
    if (clipFailed) return 'Saved — clipboard failed';
    return 'Capture failed';
  }

  @override
  Widget build(BuildContext context) {
    final d = _display;
    final frozen = _frozen;
    final editor = _editor;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      theme: ThemeData(scaffoldBackgroundColor: Colors.transparent),
      home: (d == null || frozen == null || editor == null)
          // Idle: fully transparent until a capture sets the frozen frame.
          ? const SizedBox.shrink()
          // Every display builds the editor; EditorCanvas shows the interactive
          // HUD/toolbar only while the cursor is over THIS display, and asks
          // native to make this window key on entry — so the editor follows the
          // cursor across displays (design §7, cross-display follow).
          : Stack(
              fit: StackFit.expand,
              children: [
                EditorCanvas(
                  key: ValueKey(_captureSeq),
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
                ),
                // Dim + lock the freeze while a ⌘, Settings detour is open.
                if (_settingsOpen) const SettingsMask(),
              ],
            ),
    );
  }
}
