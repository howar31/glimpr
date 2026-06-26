import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../l10n/gen/app_localizations.dart';
import '../settings/app_locale.dart';
import '../settings/prefs_cache.dart';
import '../editor/draw_style.dart';
import '../editor/document.dart';
import '../editor/editor_controller.dart';
import '../editor/editor_core.dart';
import '../editor/hud_config.dart';
import '../editor/loupe_config.dart';
import '../editor/tool_style_store.dart';
import '../editor/viewport.dart';
import '../overlay/toolbar.dart';
import '../output/clipboard.dart';
import '../output/deliver.dart';
import '../output/flow.dart';
import '../output/output_naming.dart';
import '../output/sounds.dart';
import '../perf/frame_stats.dart';
import '../perf/perf_gate.dart';
import '../settings/settings.dart';
import '../settings/settings_mask.dart';
import '../shortcuts/hotkey_binding.dart';
import '../shortcuts/shortcut_actions.dart';
import '../shortcuts/shortcut_store.dart';
import '../theme/confirm_dialog.dart';
import '../theme/glimpr_controls.dart';
import '../theme/glimpr_theme.dart';
import 'checkerboard.dart';
import 'gallery_layout.dart';
import 'image_editor_export.dart';
import 'image_editor_host.dart';
import 'recent_images.dart';
import 'thumb_cache.dart';

/// Standalone Image Editor window in the Aurora design language (same theme as
/// the Settings window, following the system light/dark appearance). The native
/// window uses behind-window dark vibrancy with a hidden/transparent OS title,
/// so a 44px Flutter title bar runs across the top in both states.
///
/// Landing state: an Aurora card prompting the user to open an image. Loaded
/// state: a checkerboard transparency canvas with the fitted image (rounded,
/// bordered, drop-shadowed) filling the area, and a fixed, centered glass
/// toolbar PILL floating over it near the bottom — the shared [EditorToolbar]
/// rendered without its drag handle, with undo/redo + Open/Copy/Save as trailing
/// actions inside the same glass bar. Copy/Save composite the annotated image
/// and deliver it.
class ImageEditorApp extends StatefulWidget {
  const ImageEditorApp({super.key});

  @override
  State<ImageEditorApp> createState() => _ImageEditorAppState();
}

class _ImageEditorAppState extends State<ImageEditorApp>
    with WidgetsBindingObserver {
  // Resolved from a context inside the MaterialApp's Localizations scope (set
  // in the Builder in build()). Using a field instead of a context-arg avoids
  // threading the parameter through every private helper.
  late AppLocalizations _l;
  ui.Image? _image;
  Uint8List? _bytes;
  String _sourceName = 'image';
  EditorController? _controller;
  // Single in-flight guard shared by Copy + Save so rapid clicks never double-fire.
  bool _exporting = false;
  // True once the loaded image has any annotations; cleared on save or on unload.
  bool _dirty = false;
  bool _closePending = false;
  bool _confirming = false;
  // Top-centred toast pill (see _toast): the message, its visibility (drives
  // the fade/slide), and the auto-dismiss + post-fade clear timers.
  String? _toastMsg;
  bool _toastVisible = false;
  Timer? _toastTimer;
  Timer? _toastClearTimer;
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final ValueNotifier<({int id, Offset cursor})> _active = ValueNotifier(
    (id: ImageEditorHost.kImageEditorHostId, cursor: Offset.zero),
  );

  final Map<ToolKind, DrawStyle> _toolStyles = {};
  Timer? _persistTimer; // debounces saving _toolStyles to the shared store
  Map<String, HotkeyBinding?> _bindings = {...effectiveDefaultBindings()};
  LoupeConfig _loupe = const LoupeConfig();
  HudConfig _hud = const HudConfig();
  CaptureSettings _cap = CaptureSettings.defaults;
  // Mask state derived from the GLOBAL "Settings open" signal + this window's
  // active state: mask when Settings is open AND the editor isn't the active
  // window. So it is correct regardless of order (e.g. Settings opened from the
  // menu first, then the editor).
  bool _settingsVisible = false;
  bool _windowActive = false;
  bool get _showSettingsMask => _settingsVisible && !_windowActive;
  // Drives EditorCore's Fit / 100% from the docked toolbar buttons.
  final EditorViewportController _viewport = EditorViewportController();

  RecentImagesStore? _recentStore;
  List<String> _recent = const [];

  static const _channel = MethodChannel('glimpr/imageEditor');

  // Perf instrumentation (perf-tune plan M1/M3/M4/M5): named marks + frame
  // summaries over this engine's own channel (it has no glimpr/capture
  // handler), landing in the unified-log perf category.
  late final FrameStatsReporter _frames =
      FrameStatsReporter(tag: 'editor', sink: _perfMark);
  bool _galleryReadyMarked = false;

  void _perfMark(String label) {
    _channel
        .invokeMethod('perfMark', {'label': label})
        .then((_) {}, onError: (_) {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Frame-stat sampling is measurement-only: register the per-frame callback
    // ONLY under the debug gate (mirrors native PerfLog.enabled). Inert in
    // normal use; a few early frames during a measurement run are not sampled.
    perfGateEnabled().then((on) {
      if (on && mounted) _frames.attach();
    });
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _perfMark('editorFirstFrame'));

    // Prefetch per-tool styles, hotkey bindings, and capture settings.
    // Each block is in its own try/catch so a synchronous store construction
    // error (e.g. SharedPreferences platform not set in tests) does not prevent
    // the widget from building; the defaults seeded above are used instead.
    try {
      ToolStyleStore(Settings.instance.store).load().then((styles) {
        if (mounted) setState(() => _toolStyles..addAll(styles));
      }).catchError((_) {});
    } catch (_) {}

    try {
      ShortcutStore(Settings.instance.store).all().then((b) {
        if (mounted) setState(() => _bindings = b);
      }).catchError((_) {});
    } catch (_) {}

    try {
      Settings.instance.loadCapture().then((c) {
        if (mounted) setState(() => _cap = c);
      }).catchError((_) {});
    } catch (_) {}

    try {
      Settings.instance.loadLoupe().then((l) {
        if (mounted) setState(() => _loupe = l);
      }).catchError((_) {});
      Settings.instance.loadHud().then((h) {
        if (!mounted) return;
        setState(() => _hud = h);
        _seedHudToggles(h);
      }).catchError((_) {});
    } catch (_) {}

    // Load the recent-images list and push it to the native menu-bar submenu.
    // The warm editor engine boots at launch, so this populates "Open Recent"
    // even before the editor window is ever revealed.
    try {
      _recentStore = RecentImagesStore(Settings.instance.store);
      _refreshRecent();
    } catch (_) {}

    // The native side sends 'loadPath' or 'requestClose' via the editor channel.
    // loadPath: user picked a file via the system Open panel (or Finder "Open With").
    // requestClose: a close gesture (red button / Cmd-W) was intercepted natively;
    // Dart runs the dirty-check dialog and, if the user confirms, calls hideEditor.
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'loadPath') {
        final path = call.arguments as String?;
        if (path != null) await _loadPath(path);
      } else if (call.method == 'loadClipboard') {
        // Open-Editor-with-Clipboard global hotkey: load the clipboard image
        // (same path as the landing ⌘V; toasts + stays on landing if empty).
        await _pasteLoad();
      } else if (call.method == 'settingsOpened') {
        if (mounted) setState(() => _settingsVisible = true);
      } else if (call.method == 'settingsClosed') {
        if (mounted) setState(() => _settingsVisible = false);
        _reload();
        // Settings took focus; hand it back to the canvas so shortcuts resume
        // (the native side re-keys the editor window).
        _controller?.requestFocus();
      } else if (call.method == 'windowBecameKey') {
        // Returning to the editor (e.g. from Settings, or Cmd-Tab back) picks up
        // any change AND hands keyboard focus back to the canvas, so tool
        // shortcuts work without a manual click.
        if (mounted) setState(() => _windowActive = true);
        _controller?.requestFocus();
        _reload();
        // Belt-and-braces: captures may have fed the shared recent store
        // while this window was in the background.
        _refreshRecent();
      } else if (call.method == 'windowResignedKey') {
        if (mounted) setState(() => _windowActive = false);
      } else if (call.method == 'requestClose') {
        await _requestClose();
      } else if (call.method == 'clearRecent') {
        // The menu-bar "Open Recent" → "Clear Menu" item; Dart owns the list.
        await _clearRecent();
      } else if (call.method == 'refreshRecent') {
        // A capture flow saved a file into the shared recent store.
        await _refreshRecent();
      }
    });
    // Tell native the handler is installed so a Finder "Open With" that arrived
    // during a cold start can be flushed to us.
    try {
      _channel.invokeMethod('editorReady');
    } catch (_) {}
  }

  // Follow the system appearance: rebuild when it flips so the token set swaps.
  @override
  void didChangePlatformBrightness() => setState(() {});

  /// Mark the current image as having unsaved annotations.
  void _markDirty() {
    if (!_dirty && mounted) setState(() => _dirty = true);
  }

  /// Open the native file-picker panel; the native side returns the chosen path.
  Future<void> _openPanel() async {
    // Confirm BEFORE the file picker appears, so unsaved work isn't lost behind it.
    if (!await _confirmDiscardIfDirty()) return;
    try {
      final path = await _channel.invokeMethod<String>('openPanel');
      if (path != null && mounted) await _loadPath(path, confirmed: true);
    } catch (_) {
      // Channel unavailable (e.g. test environment) or user cancelled — ignore.
    }
  }

  /// Read, decode, and show [path] in the editor.
  Future<void> _loadPath(String path, {bool confirmed = false}) async {
    // Replacing the current image: confirm if dirty — unless the caller already
    // did (the Open button confirms BEFORE showing the file picker). Direct loads
    // (Finder "Open With" / drag-drop, later) pass confirmed=false.
    if (!confirmed && !await _confirmDiscardIfDirty()) return;
    _perfMark('editorOpenBegin kind=file');
    late final Uint8List bytes;
    try {
      bytes = await File(path).readAsBytes();
    } catch (e) {
      _toast(_l.editorToastCannotReadFile('$e'));
      return;
    }

    ui.Image img;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      img = frame.image;
      codec.dispose();
    } catch (e) {
      _toast(_l.editorToastCannotDecodeImage('$e'));
      return;
    }

    if (!mounted) {
      img.dispose();
      return;
    }
    _setLoadedImage(bytes, img, p.basenameWithoutExtension(path));
    await _recordRecent(path);
  }

  /// Record a successfully-opened file path in the recent list and refresh both
  /// the landing list and the native menu. Pastes have no path → not recorded.
  /// Temp files (e.g. the capture flow's open-in-editor without a save) are
  /// transient — recording them would leave dead /tmp entries until pruned.
  Future<void> _recordRecent(String path) async {
    final store = _recentStore;
    if (store == null) return;
    if (p.isWithin(Directory.systemTemp.path, path)) return;
    try {
      await store.add(path);
    } catch (_) {
      return;
    }
    await _refreshRecent();
  }

  /// Drop one entry from the recent list (tile context menu).
  Future<void> _removeRecent(String path) async {
    final store = _recentStore;
    if (store == null) return;
    try {
      await store.remove(path);
    } catch (_) {
      return;
    }
    await _refreshRecent();
  }

  /// Empty the recent list (tile context menu / native "Clear Menu").
  Future<void> _clearRecent() async {
    final store = _recentStore;
    if (store == null) return;
    try {
      await store.clear();
    } catch (_) {
      return;
    }
    await _refreshRecent();
  }

  /// Reveal a recent file in Finder (tile context menu). Same mechanism as the
  /// completion flow's showInFinder leg.
  void _revealRecent(String path) {
    Process.run('open', ['-R', path]);
  }

  /// The gallery's trailing "More…" tile: open the save folder in Finder —
  /// the gallery shows the capped recents, the folder holds everything.
  void _openSaveFolder() {
    Process.run('open', [effectiveSaveDir(_cap.saveDir).path]);
  }

  /// Copy a recent file's image to the clipboard (tile context menu). Same
  /// pasteboard call as the delivery copy leg.
  Future<void> _copyRecent(String path) async {
    try {
      await clipboardWriteImage(await File(path).readAsBytes());
      _toast(_l.editorToastCopiedToClipboard);
    } catch (_) {
      _toast(_l.editorToastCopyFailed);
    }
  }

  /// Pin a recent file as a floating window (tile context menu). Routed over
  /// the editor channel like the Done flow's pin leg (no origin → centered).
  void _pinRecent(String path) {
    try {
      _channel.invokeMethod('pinImage', {'path': path});
    } catch (_) {}
  }

  /// Copy a recent file's path to the clipboard (tile context menu).
  Future<void> _copyRecentPath(String path) async {
    await Clipboard.setData(ClipboardData(text: path));
    _toast(_l.editorToastPathCopied);
  }

  /// Share a recent file via the macOS share sheet (tile context menu) —
  /// anchored to the menu-bar icon like every other share source.
  void _shareRecent(String path) {
    try {
      _channel.invokeMethod('shareSheet', {'path': path});
    } catch (_) {}
  }

  /// Aurora confirm before emptying the recent list (the tile context menu's
  /// Clear Recent). The native "Clear Menu" item stays direct — that is the
  /// macOS document-app convention, and the editor window may be hidden.
  Future<void> _confirmClearRecent() async {
    final ctx = _navigatorKey.currentContext;
    if (ctx == null) return;
    final ok = await showDiscardConfirm(
      ctx,
      title: _l.editorClearRecentTitle,
      message: _l.editorClearRecentMessage(_recent.length),
      confirmLabel: _l.editorClearRecentConfirm,
    );
    if (ok) await _clearRecent();
  }

  /// Reload the recent list, drop entries whose file is gone, then update the
  /// landing list and push the pruned list to the native "Open Recent" submenu.
  Future<void> _refreshRecent() async {
    final store = _recentStore;
    if (store == null) return;
    List<String> list;
    try {
      // Windows: each engine caches SharedPreferences per-instance, so a recent
      // written by the capture/overlay engine is invisible here until we drop the
      // cache. No-op on macOS (process-wide NSUserDefaults). The S2b gotcha.
      await reloadSettingsCache();
      list = pruneMissing(await store.load(), (p) => File(p).existsSync());
    } catch (_) {
      return;
    }
    if (!mounted) return;
    setState(() => _recent = list);
    // M3 anchor: first frame with the landing grid built. Tile thumbnails keep
    // decoding after this — the decode tail shows up in the RSS curve instead.
    if (!_galleryReadyMarked) {
      _galleryReadyMarked = true;
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => _perfMark('editorGalleryReady count=${list.length}'));
    }
    try {
      await _channel.invokeMethod('setRecentImages', list);
    } catch (_) {
      // Native handler not present (e.g. tests) — the landing list still works.
    }
  }

  /// Load an image already decoded in memory (from a file read or a clipboard
  /// paste) as the editor's base: swap the image/bytes/source name and start a
  /// fresh controller on the non-destructive SELECT tool.
  Future<void> _setLoadedImage(
    Uint8List bytes,
    ui.Image img,
    String name,
  ) async {
    // Refresh the shared per-tool styles before building this session's
    // controller, so edits made in the capture overlay since this window loaded
    // are picked up (the overlay does the same reseed per capture). The map
    // instance is shared with the controller, so mutate it in place.
    try {
      final styles = await ToolStyleStore(Settings.instance.store).load();
      _toolStyles
        ..clear()
        ..addAll(styles);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _image?.dispose();
      _image = img;
      _bytes = bytes;
      _sourceName = name;
      _controller?.style.removeListener(_schedulePersist);
      _controller?.dispose();
      _controller = EditorController(toolStyles: _toolStyles);
      // Persist this surface's style edits to the shared store (debounced) so
      // the capture overlay picks them up on its next capture.
      _controller!.style.addListener(_schedulePersist);
      // Open on the non-destructive SELECT tool, not crop — in this editor a
      // crop tap would trigger Complete (export). Complete is the explicit
      // export path; tapping the canvas must not save.
      _controller!.selectTool(ToolKind.paste);
      // Listen for document mutations to flip _dirty. The previous controller
      // was disposed above, which disposes its document and clears its listeners,
      // so there is no duplicate subscription.
      _controller!.document.addListener(_markDirty);
      _seedHudToggles(_hud); // seed from the latest loaded HUD settings
      _dirty = false;
    });
    // M4 anchor: the opened image's first editable frame.
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => _perfMark('editorOpenReady w=${img.width} h=${img.height}'));
  }

  void _schedulePersist() {
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 400), () {
      ToolStyleStore(Settings.instance.store).save(Map.of(_toolStyles));
    });
  }

  /// Load the clipboard image as the base (landing-state ⌘V). When an image is
  /// already loaded, EditorCore owns ⌘V (paste-as-annotation), so this handler is
  /// only live on the landing state. Confirms-if-dirty (a no-op on landing).
  Future<void> _pasteLoad() async {
    if (!await _confirmDiscardIfDirty()) return;
    _perfMark('editorOpenBegin kind=clipboard');
    Uint8List? bytes;
    try {
      bytes = await clipboardReadImage();
    } catch (_) {
      return; // clipboard channel unavailable (e.g. tests)
    }
    if (bytes == null) {
      _toast(_l.editorToastNoImageInClipboard);
      return;
    }
    ui.Image img;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      img = frame.image;
      codec.dispose();
    } catch (e) {
      _toast(_l.editorToastCannotDecodeClipboard);
      return;
    }
    if (!mounted) {
      img.dispose();
      return;
    }
    _setLoadedImage(bytes, img, 'pasted');
  }

  /// Reveal the Settings window (⌘, — from the editor canvas or the landing).
  /// The mask + state come from the native settingsOpened / window-key broadcasts
  /// (single source of truth), so this only requests the reveal.
  void _openSettings() {
    try {
      _channel.invokeMethod('openSettings');
    } catch (_) {}
  }

  /// Hot-reload the WHOLE config bundle ([Settings.loadAppConfig]: loupe + HUD +
  /// capture/output + editor bindings) on a Settings-close / window-key — a new
  /// config setting hot-reloads here for free just by joining AppConfig.
  /// Deliberately does NOT re-read in-session interaction state (the in-progress
  /// tool styles, the current tool / selection), so returning never clobbers what
  /// the user is doing.
  void _reload() {
    Settings.instance.loadAppConfig().then((cfg) {
      if (mounted) {
        setState(() {
          _loupe = cfg.loupe;
          _hud = cfg.hud;
          _cap = cfg.capture;
          _bindings = cfg.bindings;
        });
        _seedHudToggles(cfg.hud);
      }
    }).catchError((_) {});
  }

  /// Seed the controller's HUD toggle state from settings, UNLESS the user
  /// already flipped a toggle this session (don't clobber an in-session
  /// override). Resets naturally when a new image opens (new controller).
  void _seedHudToggles(HudConfig h) {
    final ed = _controller;
    if (ed == null || ed.hudUserToggled) return;
    ed.crosshairOn.value = h.crosshair;
    ed.loupeOn.value = h.loupe;
  }

  /// Done: run the user-configured after-editor flow (Settings), then CLOSE the
  /// editor — Done means the work is finished, unlike the one-off ▾ actions
  /// which keep the window open. A failed leg keeps the window open so the
  /// error toast can be acted on.
  Future<void> _done() async {
    final flow = await Settings.instance.getAfterEditorDoneFlow();
    final ok = await _runActions(normalizeFlow(flow, forCapture: false));
    // Done always closes on success — the share picker (if in the flow) is
    // anchored to the menu-bar icon, so it survives the window going away.
    if (ok && mounted) await _closeAndReset();
  }

  /// Run [actions] (the Done flow or a one-off from the chevron menu) over the
  /// composited image and toast the outcome. Returns true when EVERY requested
  /// leg succeeded. The shared [_exporting] guard covers Done and every one-off
  /// so rapid clicks don't re-fire.
  Future<bool> _runActions(Set<FlowAction> actions) async {
    final baseImage = _image, controller = _controller;
    if (baseImage == null || controller == null || _exporting) return false;
    setState(() => _exporting = true);
    _perfMark(
        'editorExportBegin actions=${actions.map((a) => a.name).join(',')}');
    try {
      final cap = _cap;
      // The editor's "shutter": Done/export is the commit moment (parallel to a
      // capture). The menu-bar processing pulse runs until the output delivers.
      if (cap.shutterSound) playShutter();
      _setProcessing(true);
      // After a crop-trim the document carries the smaller canvas image; export
      // that (and the already-shifted drawables), else the untrimmed base.
      final doc = controller.document.value;
      // Respect the shared output settings exactly like every capture/recording
      // leg: save dir + subfolder + filename template (owner: drop the old
      // "-edited" name, the editor now names like a capture). %title resolves to
      // the source image's name.
      final naming = await resolveCaptureNaming(
        cap: cap,
        ext: cap.isJpeg ? 'jpg' : 'png',
        windowTitle: _sourceName,
        appName: _sourceName,
      );
      final result = await exportImage(
        image: doc.canvasImage ?? baseImage,
        drawables: doc.drawables,
        jpeg: cap.isJpeg,
        jpegQuality: cap.jpegQuality,
        actions: actions,
        saveDir: naming.dir,
        fileName: naming.fileName,
        // Route the share/pin legs over the editor's own channel (this engine
        // has no glimpr/capture handler); share anchors to the menu-bar icon,
        // pin centers (no origin rect from the editor).
        shareFn: (path) => _channel.invokeMethod('shareSheet', {'path': path}),
        pinFn: (path) => _channel.invokeMethod('pinImage', {'path': path}),
        perfMark: _perfMark,
      );
      _perfMark('editorExportDone');
      if (!mounted) return false;
      // Clear dirty only on a confirmed file save, not on clipboard copy.
      if (actions.contains(FlowAction.save) && result.savedOk) {
        setState(() => _dirty = false);
        // The saved output is a real artifact — put it in Open Recent (macOS
        // document-app convention), so Done/Save feed the list too.
        await _recordRecent(result.savedPath!);
      }
      _toast(_flowToast(actions, result));
      final ok =
          (!actions.contains(FlowAction.copy) || result.copiedToClipboard) &&
              (!actions.contains(FlowAction.save) || result.savedOk) &&
              result.extraErrors.isEmpty;
      // Same completion chime as a capture's delivery (the editor has no
      // shutter moment, so completion is its only sound), behind the same
      // Workflow > Sounds toggle.
      if (ok && cap.completionSound) playComplete();
      return ok;
    } finally {
      _setProcessing(false);
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// Drive the menu-bar processing pulse from the editor engine (handled by the
  /// control engine over `glimpr/imageEditor`). Fire-and-forget.
  void _setProcessing(bool active) {
    _channel
        .invokeMethod('setProcessing', {'active': active})
        .then((_) {}, onError: (_, _) {});
  }

  /// One line summarizing every leg the flow ran, e.g. "Copied · Saved" or
  /// "Saved to /path · Copy failed".
  String _flowToast(Set<FlowAction> actions, FlowResult r) {
    final parts = <String>[
      if (actions.contains(FlowAction.copy))
        r.copiedToClipboard ? _l.editorToastCopied : _l.editorToastCopyFlowFailed,
      if (actions.contains(FlowAction.save))
        r.savedOk ? _l.editorToastSavedTo(r.savedPath!) : _l.editorToastSaveFailed,
      if (actions.contains(FlowAction.copyPath))
        r.errors.containsKey('copyPath') ? _l.editorToastCopyPathFailed : _l.editorToastPathCopied,
      if (actions.contains(FlowAction.showInFinder))
        if (r.errors.containsKey('showInFinder')) _l.editorToastRevealFailed,
      if (actions.contains(FlowAction.shareSheet))
        if (r.errors.containsKey('shareSheet')) _l.editorToastShareFailed,
      if (actions.contains(FlowAction.pin))
        r.errors.containsKey('pin') ? _l.editorToastPinFailed : _l.editorToastPinned,
    ];
    return parts.isEmpty ? _l.editorToastDone : parts.join(' · ');
  }

  /// Aurora-styled "discard unsaved changes?" confirmation. Returns true to
  /// proceed (discard), false to cancel. Re-entrancy-guarded so two triggers
  /// (e.g. Cmd-W + Open) never stack dialogs.
  Future<bool> _confirmDiscard() async {
    final ctx = _navigatorKey.currentContext;
    if (ctx == null || _confirming) return false;
    _confirming = true;
    try {
      return await showDiscardConfirm(
        ctx,
        title: _l.editorDiscardTitle,
        message: _l.editorDiscardMessage,
      );
    } finally {
      _confirming = false;
    }
  }

  /// True when there is nothing to lose; otherwise prompts. Used before replacing
  /// or unloading the current image (close, Open, and later paste / drag-drop).
  Future<bool> _confirmDiscardIfDirty() async {
    if (!_dirty || _image == null) return true;
    return _confirmDiscard();
  }

  /// Handle a close gesture from native (red button or Cmd-W): confirm if dirty,
  /// then hide + unload via [_closeAndReset].
  Future<void> _requestClose() async {
    if (_closePending) return;
    _closePending = true;
    try {
      if (!await _confirmDiscardIfDirty()) return;
      await _closeAndReset();
    } finally {
      _closePending = false;
    }
  }

  /// Tell native to hide the window (engine stays warm), then dispose + reset the
  /// loaded image so the NEXT open shows the landing state.
  Future<void> _closeAndReset() async {
    try {
      await _channel.invokeMethod('hideEditor');
    } catch (_) {}
    _unloadImage();
  }

  /// Dispose + reset the loaded image; the editor falls back to the landing.
  void _unloadImage() {
    if (!mounted) return;
    setState(() {
      _image?.dispose();
      _image = null;
      _bytes = null;
      _controller?.style.removeListener(_schedulePersist);
      _controller?.dispose();
      _controller = null;
      _dirty = false;
    });
  }

  /// Toolbar "Open": back to the landing (the open hub — recents grid, Open
  /// panel, drag, ⌘V) instead of jumping straight into the file dialog.
  /// Confirms first when there are unsaved annotations.
  Future<void> _backToLanding() async {
    if (!await _confirmDiscardIfDirty()) return;
    _unloadImage();
  }

  /// Show the top-centred toast pill (replaces the old floating SnackBar,
  /// which rose from the bottom and covered the toolbar pill). Repeated calls
  /// restart the timer with the new message.
  void _toast(String message) {
    _toastTimer?.cancel();
    _toastClearTimer?.cancel();
    setState(() {
      _toastMsg = message;
      _toastVisible = true;
    });
    _toastTimer = Timer(const Duration(milliseconds: 2400), () {
      if (mounted) setState(() => _toastVisible = false);
      // Drop the text only after the fade-out finishes so it never flashes.
      _toastClearTimer = Timer(const Duration(milliseconds: 250), () {
        if (mounted) setState(() => _toastMsg = null);
      });
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _frames.detach();
    _persistTimer?.cancel();
    _toastTimer?.cancel();
    _toastClearTimer?.cancel();
    _image?.dispose();
    _controller?.style.removeListener(_schedulePersist);
    _controller?.dispose();
    _active.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final brightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    final tokens = GlimprTokens.forBrightness(brightness);
    final image = _image;
    final bytes = _bytes;
    final controller = _controller;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      locale: appLocaleOverride,
      localeListResolutionCallback: resolveAppLocale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(
        brightness: brightness,
        scaffoldBackgroundColor: Colors.transparent,
        fontFamily: GlimprType.sans,
        tooltipTheme: glimprTooltipTheme(brightness),
      ),
      home: GlimprTheme(
        tokens: tokens,
        // Transparent scaffold = the window is pure native vibrancy (design
        // guide — Apple liquid glass). The editor CANVAS supplies its own
        // opaque checkerboard worktable; the title bar + landing read as
        // glass chrome over the vibrancy, matching the Settings window.
        //
        // Windows: an ancestor Ctrl+W closes the editor (macOS uses the native
        // ⌘W window intercept). canRequestFocus:false so it never steals focus;
        // key events bubble up here from the focused canvas/landing, which
        // ignore Ctrl+W, so this is a safe last-resort handler in both states.
        child: Focus(
          canRequestFocus: false,
          onKeyEvent: (node, e) {
            if (Platform.isWindows &&
                e is KeyDownEvent &&
                HardwareKeyboard.instance.isControlPressed &&
                e.logicalKey == LogicalKeyboardKey.keyW) {
              _requestClose();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Scaffold(
          backgroundColor: Colors.transparent,
          // A 44px Flutter title bar runs across the top in BOTH states (the OS
          // title is hidden + transparent), with the state content filling below.
          body: Builder(
            builder: (ctx) {
              // Resolve localizations from a context that is inside the
              // MaterialApp's Localizations scope (not the outer context).
              _l = AppLocalizations.of(ctx);
              return Stack(
                children: [
                  Column(
                    children: [
                      // The Flutter title bar is macOS-only (its frameless
                      // .fullSizeContentView chrome). Windows keeps the standard
                      // OS caption, so the content fills from the top and Home
                      // becomes a floating button over the canvas (below).
                      if (!Platform.isWindows) _titleBar(tokens),
                      Expanded(
                        child:
                            (image == null || bytes == null || controller == null)
                            ? _landing(tokens)
                            : _editor(tokens, image, bytes, controller),
                      ),
                    ],
                  ),
                  // Windows: a floating glass Home button at the canvas top-left
                  // while editing (the landing/gallery is itself "home").
                  if (Platform.isWindows && image != null)
                    Positioned(
                      top: 12,
                      left: 12,
                      child: _FloatingHomeButton(onTap: _backToLanding),
                    ),
                  // Toast: a top-centred glass pill just below the title bar —
                  // away from the bottom toolbar pill (the old floating SnackBar
                  // covered it). Non-interactive; fades + slides in/out.
                  Positioned(
                    top: 32 + 12,
                    left: 24,
                    right: 24,
                    child: IgnorePointer(
                      child: AnimatedSlide(
                        offset:
                            _toastVisible ? Offset.zero : const Offset(0, -0.4),
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutCubic,
                        child: AnimatedOpacity(
                          opacity: _toastVisible ? 1 : 0,
                          duration: const Duration(milliseconds: 220),
                          child: Center(
                            child: _toastMsg == null
                                ? const SizedBox.shrink()
                                : Container(
                                    constraints:
                                        const BoxConstraints(maxWidth: 560),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 16, vertical: 9),
                                    decoration: BoxDecoration(
                                      color: tokens.hudBg,
                                      borderRadius: BorderRadius.circular(
                                          GlimprTokens.radiusBar),
                                      border:
                                          Border.all(color: tokens.hudBorder),
                                      boxShadow: [
                                        BoxShadow(
                                          color: tokens.isDark
                                              ? const Color(0x66000000)
                                              : const Color(0x2E0F172A),
                                          blurRadius: 16,
                                        ),
                                      ],
                                    ),
                                    child: Text(
                                      _toastMsg!,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: GlimprType.sansStyle(
                                          13.5, 600, tokens.fg1),
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Dim + lock the editor while Settings is open and the editor
                  // isn't the active window (correct regardless of open order).
                  if (_showSettingsMask) const SettingsMask(),
                ],
              );
            },
          ),
        ),
        ),
      ),
    );
  }

  /// The 44px window title bar (both states). Translucent, with a hairline
  /// bottom border; after a left inset clearing the macOS traffic lights it
  /// shows a brand-gradient dot + the "Image Editor" label. Drawn in Flutter
  /// because the native title is hidden + transparent (.fullSizeContentView).
  Widget _titleBar(GlimprTokens t) {
    return GestureDetector(
      // The Flutter title bar covers the native one, so AppKit never sees a
      // double-click; forward it to native to run the system title-bar action.
      behavior: HitTestBehavior.opaque,
      onDoubleTap: () {
        try {
          _channel.invokeMethod('titleBarDoubleClick');
        } catch (_) {}
      },
      child: Container(
        // Height tuned so the centred logo + title line up vertically with the
        // native traffic-light buttons (their centre sits ~16px from the top):
        // content centres at height/2, so 32px puts it at 16px. (44px was too
        // low, 28px slightly too high.)
        height: 32,
        // Glass chrome: no fill, so the window vibrancy shows through (design
        // guide — no tint). A hairline divider separates it from the canvas /
        // landing below; logo + title read over the frosted vibrancy like the
        // Settings sidebar header.
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: t.divider)),
        ),
        child: Row(
          children: [
            // Left inset to clear the macOS traffic-light buttons. (This bar is
            // macOS-only — Windows uses the OS caption + a floating Home button.)
            const SizedBox(width: 78),
            // Back to the gallery landing — navigation lives top-left next to
            // the window controls (macOS back idiom), NOT in the bottom action
            // pill. Editor state only; the landing has nowhere to go back to.
            if (_image != null) ...[
              _TitleBarHome(onTap: _backToLanding),
              const SizedBox(width: 6),
            ],
            // The Viewfinder logo mark (same as the Settings sidebar), replacing
            // the former decorative brand dot.
            const GlimprMark(size: 18),
            const SizedBox(width: 9),
            Text(
              _l.editorTitleBar,
              style: GlimprType.sansStyle(13, 600, t.fg2, letterSpacing: -0.1),
            ),
          ],
        ),
      ),
    );
  }

  /// Landing state: an Aurora card prompting the user to open an image. Paste /
  /// drag-drop / Open Recent are later blocks — only the static hint + the Open
  /// button are wired now.
  Widget _landing(GlimprTokens t) {
    // Landing-only ⌘V loads the clipboard image as the base (when loaded,
    // EditorCore owns ⌘V for paste-as-annotation). Autofocus so the shortcut is
    // live without a click; the field/canvas takes focus once an image loads.
    return Focus(
      autofocus: true,
      onKeyEvent: (node, e) {
        // The command modifier is platform-aware: ⌘ on macOS, Ctrl on Windows.
        final cmd = Platform.isWindows
            ? HardwareKeyboard.instance.isControlPressed
            : HardwareKeyboard.instance.isMetaPressed;
        if (e is KeyDownEvent &&
            cmd &&
            e.logicalKey == LogicalKeyboardKey.comma) {
          _openSettings(); // ⌘, works on the landing too (EditorCore unmounted)
          return KeyEventResult.handled;
        }
        if (e is KeyDownEvent && cmd && e.logicalKey == LogicalKeyboardKey.keyV) {
          _pasteLoad();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: _recent.isEmpty
          ? Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: _openCard(t),
              ),
            )
          : _gallery(t),
    );
  }

  /// Gallery landing: a slim open bar on top, then a scrollable grid of the
  /// recent images (captures and opened files) filling the rest of the window.
  Widget _gallery(GlimprTokens t) {
    // The grid's horizontal inset lives INSIDE the scroll view (not on an
    // outer Padding): the viewport then spans the window, so the overlay
    // scrollbar draws at the window edge instead of over the last column.
    // Visual margins are unchanged (28px all the same).
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: _openBar(t),
          ),
          const SizedBox(height: 22),
          Padding(
            padding: const EdgeInsets.only(left: 28),
            child: Text(
              _l.editorGalleryRecent,
              style: GlimprType.sansStyle(11, 700, t.fg4, letterSpacing: 0.4),
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            // Tiles grow with the window (galleryColumns: fewest columns whose
            // rows still fit the viewport, tile width clamped min..max) so a
            // large window fills with content instead of dead space.
            child: LayoutBuilder(
              builder: (context, box) => GridView.builder(
              padding: const EdgeInsets.fromLTRB(28, 0, 28, 24),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                // +1 = the trailing "More…" utility tile; the cap is a
                // multiple of the min-width column count minus one, so the
                // grid closes as a full rectangle at the smallest window.
                // Width minus the grid's own horizontal padding (28 + 28).
                crossAxisCount: galleryColumns(
                    box.maxWidth - 56, box.maxHeight - 24, _recent.length + 1),
                mainAxisSpacing: kGallerySpacing,
                crossAxisSpacing: kGallerySpacing,
                childAspectRatio: kGalleryTileRatio,
              ),
              itemCount: _recent.length + 1,
              itemBuilder: (_, i) {
                if (i == _recent.length) {
                  return _MoreTile(onTap: _openSaveFolder);
                }
                final path = _recent[i];
                return _RecentTile(
                  path: path,
                  onTap: () => _loadPath(path),
                  onCopy: () => _copyRecent(path),
                  onCopyPath: () => _copyRecentPath(path),
                  onShare: () => _shareRecent(path),
                  onPin: () => _pinRecent(path),
                  onReveal: () => _revealRecent(path),
                  onRemove: () => _removeRecent(path),
                  onClear: _confirmClearRecent,
                );
              },
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Slim opening bar over the gallery — the centred open card compressed to
  /// one row: the brand lockup (same as the Settings sidebar header), the Open
  /// button, and the drag/paste hint.
  Widget _openBar(GlimprTokens t) {
    return GlassCard.padded(
      pad: 14,
      child: Row(
        children: [
          const SizedBox(width: 4),
          const Lockup(),
          const SizedBox(width: 18),
          AccentButton(
            _l.editorOpenImageButton,
            icon: Icons.image_outlined,
            onTap: _openPanel,
          ),
          const SizedBox(width: 14),
          Text(
            _l.editorOpenImageHint,
            style: GlimprType.sansStyle(11.5, 500, t.fg4),
          ),
        ],
      ),
    );
  }

  /// The Aurora "open an image" prompt card (logo, copy, Open button, hints).
  Widget _openCard(GlimprTokens t) {
    return GlassCard.padded(
      pad: 36,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const GlimprMark(size: 56),
          const SizedBox(height: 22),
          Text(
            _l.editorOpenImage,
            textAlign: TextAlign.center,
            style: GlimprType.sansStyle(
              18,
              700,
              t.fg1,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _l.editorOpenImageSubtitle,
            textAlign: TextAlign.center,
            style: GlimprType.sansStyle(13, 400, t.fg3, height: 1.45),
          ),
          const SizedBox(height: 24),
          AccentButton(
            _l.editorOpenImageButton,
            icon: Icons.image_outlined,
            onTap: _openPanel,
          ),
          const SizedBox(height: 12),
          Text(
            _l.editorOpenImageHint,
            textAlign: TextAlign.center,
            style: GlimprType.sansStyle(11.5, 500, t.fg4),
          ),
        ],
      ),
    );
  }

  /// Loaded state: a checkerboard transparency canvas with the fitted image
  /// (drop-shadowed) filling the area, and a fixed, centered glass toolbar PILL
  /// floating over it near the bottom (the pill IS the shared [EditorToolbar]'s
  /// own glass bar; its option row floats above it over the canvas).
  Widget _editor(
    GlimprTokens t,
    ui.Image image,
    Uint8List bytes,
    EditorController controller,
  ) {
    return Stack(
      children: [
        Positioned.fill(child: _canvas(t, image, bytes, controller)),
        // Fixed, centered floating pill ~18px from the bottom — not draggable.
        Positioned(
          left: 0,
          right: 0,
          bottom: 18,
          child: Center(child: _toolbarPill(t, controller)),
        ),
      ],
    );
  }

  /// The canvas area: a checkerboard transparency backdrop with [EditorCore]
  /// filling the whole area. EditorCore now owns the viewport — it fits/centres
  /// the native-sized image inside the area and paints the image's rounded
  /// border + drop shadow itself (the owner's image card), so there is no
  /// app-level fitted SizedBox or shadow frame here (it would double otherwise).
  Widget _canvas(
    GlimprTokens t,
    ui.Image image,
    Uint8List bytes,
    EditorController controller,
  ) {
    final host = ImageEditorHost(
      image: image,
      bytes: bytes,
      onComplete: _done,
      activeSignal: _active,
      onOpenSettings: _openSettings,
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        Checkerboard(dark: t.isDark),
        Positioned.fill(
          child: EditorCore(
            key: ValueKey(image), // fresh State per loaded image
            controller: controller,
            editorBindings: _bindings,
            loupe: _loupe,
            hud: _hud,
            host: host,
            viewportController: _viewport,
          ),
        ),
      ],
    );
  }

  /// The floating toolbar pill: the shared [EditorToolbar] (no drag handle, not
  /// draggable) with undo/redo + Open/Copy/Save as trailing actions inside its
  /// own glass bar. Its contextual option row grows UPWARD above the bar, over
  /// the canvas. No wrapping background — the pill IS the toolbar's glass bar.
  // [t] is passed in (not GlimprTheme.of): this method runs off the State's
  // root context, which sits ABOVE the GlimprTheme scope built in [build].
  Widget _toolbarPill(GlimprTokens t, EditorController controller) {
    // The pill is the toolbar's own glass bar at its natural width (centred by the
    // caller). NOT wrapped in a full-width horizontal scroll view — that scrollable
    // intercepted the whole bottom strip, blocking drawing left/right of the pill.
    return EditorToolbar(
      controller: controller,
      editorBindings: _bindings,
      showDragHandle: false,
      onMove: (_) {}, // fixed — not draggable
      onPtEditingDone: () {}, // focus refinement is a later 微調
      trailing: [
          // View controls: fit-to-window / actual size (also ⌘1 / ⌘2).
          _IconAction(
            icon: Icons.fit_screen_outlined,
            tooltip: _l.editorViewFitToWindow,
            onTap: _viewport.fit,
          ),
          _IconAction(
            icon: Icons.crop_free,
            tooltip: _l.editorViewActualSize,
            onTap: _viewport.actualSize,
          ),
          const SizedBox(width: 8),
          _HistoryButtons(controller: controller),
          const SizedBox(width: 8),
          // Done = run the configured after-editor flow (Settings). The chevron
          // offers one-off deviations that run INSTEAD of the flow. (Home moved
          // to the title bar's top-left — navigation, not an action.)
          _BarAction(
            icon: Icons.check,
            label: _l.editorDoneButton,
            accent: true,
            onTap: _exporting ? null : _done,
          ),
          PopupMenuButton<Set<FlowAction>>(
            tooltip: _l.editorMenuOneOffTooltip,
            enabled: !_exporting,
            position: PopupMenuPosition.over,
            offset: const Offset(0, -8),
            popUpAnimationStyle: AnimationStyle.noAnimation,
            color: t.hudBg,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(GlimprTokens.radiusMenu),
              side: BorderSide(color: t.hudBorder),
            ),
            onSelected: _runActions,
            // The menu route lives in the app overlay, ABOVE the GlimprTheme
            // scope — pass the tokens in rather than re-reading them there.
            itemBuilder: (_) => [
              _oneOff(t, _l.editorMenuCopyOnly, Icons.copy_outlined, {FlowAction.copy}),
              _oneOff(t, _l.editorMenuSaveOnly, Icons.save_outlined, {FlowAction.save}),
              _oneOff(t, _l.editorMenuCopyFilePath, Icons.link,
                  {FlowAction.save, FlowAction.copyPath}),
              _oneOff(t, _l.editorMenuShowInFinder, Icons.folder_outlined,
                  {FlowAction.save, FlowAction.showInFinder}),
              // Share is macOS-only (no system share surface wired on Windows v1).
              if (!Platform.isWindows)
                _oneOff(t, _l.editorMenuShare, Icons.ios_share,
                    {FlowAction.shareSheet}),
              _oneOff(t, _l.editorMenuPinToScreen, Icons.push_pin_outlined,
                  {FlowAction.pin}),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Icon(Icons.expand_more, size: 18, color: t.fg2),
            ),
          ),
        ],
      );
  }

  PopupMenuItem<Set<FlowAction>> _oneOff(GlimprTokens t, String label,
          IconData icon, Set<FlowAction> actions) =>
      PopupMenuItem(
        value: actions,
        height: 36,
        child: Row(
          children: [
            Icon(icon, size: 16, color: t.fg2),
            const SizedBox(width: 10),
            Text(label, style: GlimprType.sansStyle(13.5, 500, t.fg1)),
          ],
        ),
      );
}

/// Undo / redo icon pair styled to sit inside the toolbar's glass bar, enabled
/// per the document's [EditorDocument.canUndo] / [EditorDocument.canRedo].
class _HistoryButtons extends StatelessWidget {
  const _HistoryButtons({required this.controller});
  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ValueListenableBuilder<EditorDocument>(
      valueListenable: controller.document,
      builder: (_, doc, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _IconAction(
            icon: Icons.undo,
            tooltip: l.editorUndoTooltip,
            onTap: doc.canUndo ? controller.undo : null,
          ),
          _IconAction(
            icon: Icons.redo,
            tooltip: l.editorRedoTooltip,
            onTap: doc.canRedo ? controller.redo : null,
          ),
        ],
      ),
    );
  }
}

/// A compact icon-only action button matching the toolbar's foreground palette.
/// Dims when [onTap] is null.
/// The gallery's trailing utility cell: a quiet dashed placeholder that opens
/// the save folder in Finder. Visually distinct from the photo tiles (no
/// thumbnail, dashed border) so it reads as "beyond the list", not content.
class _MoreTile extends StatefulWidget {
  const _MoreTile({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_MoreTile> createState() => _MoreTileState();
}

class _MoreTileState extends State<_MoreTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = GlimprTheme.of(context);
    final l = AppLocalizations.of(context);
    final color = _hover ? t.fg1 : t.fg3;
    // Same dynamic-size tooltip anchoring as _RecentTile.
    return LayoutBuilder(
      builder: (context, box) => MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Tooltip(
          message: l.editorGalleryMoreTooltip,
          waitDuration: const Duration(milliseconds: 400),
          verticalOffset: box.maxHeight / 2 + 8,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: _hover ? t.navHoverBg : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            // Mirror _RecentTile's geometry (thumbnail area + caption row) so
            // the dashed box aligns with the photo tiles around it.
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: CustomPaint(
                    painter: _DashedRRectPainter(
                        _hover ? t.fg3 : t.cardBorder),
                    child: SizedBox.expand(
                      child: Icon(Icons.folder_open, size: 20, color: color),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  l.editorGalleryMoreCaption,
                  maxLines: 1,
                  style: GlimprType.sansStyle(8.5, 600, color),
                ),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }
}

/// A 1px dashed rounded-rect outline (Flutter has no dashed BorderSide).
class _DashedRRectPainter extends CustomPainter {
  const _DashedRRectPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(
        (Offset.zero & size).deflate(0.5),
        const Radius.circular(8),
      ));
    const dash = 5.0, gap = 4.0;
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        final end = d + dash < metric.length ? d + dash : metric.length;
        canvas.drawPath(metric.extractPath(d, end), paint);
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRRectPainter old) => old.color != color;
}

/// The title-bar back-to-gallery control: a chevron + house pair on ONE hover
/// surface, sized for the 32px bar. Reads as navigation (Photos-style back),
/// distinct from the bottom pill's actions.
/// Windows-only floating Home button: the macOS title-bar Home, restyled as a
/// standalone glass pill that floats over the canvas (Windows has no Flutter
/// title bar to host it). Same chevron+home glyphs + tooltip + hover.
class _FloatingHomeButton extends StatefulWidget {
  const _FloatingHomeButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_FloatingHomeButton> createState() => _FloatingHomeButtonState();
}

class _FloatingHomeButtonState extends State<_FloatingHomeButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = GlimprTheme.of(context);
    final l = AppLocalizations.of(context);
    final color = _hover ? t.fg1 : t.fg2;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Tooltip(
          message: l.editorGalleryHome,
          waitDuration: const Duration(milliseconds: 400),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
            decoration: BoxDecoration(
              color: t.hudBg,
              borderRadius: BorderRadius.circular(GlimprTokens.radiusBar),
              border: Border.all(color: t.hudBorder),
              boxShadow: [
                BoxShadow(
                  color: t.isDark
                      ? const Color(0x66000000)
                      : const Color(0x2E0F172A),
                  blurRadius: 16,
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.chevron_left, size: 16, color: color),
                Icon(Icons.home_outlined, size: 15, color: color),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TitleBarHome extends StatefulWidget {
  const _TitleBarHome({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_TitleBarHome> createState() => _TitleBarHomeState();
}

class _TitleBarHomeState extends State<_TitleBarHome> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = GlimprTheme.of(context);
    final l = AppLocalizations.of(context);
    final color = _hover ? t.fg1 : t.fg2;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Tooltip(
          message: l.editorGalleryHome,
          waitDuration: const Duration(milliseconds: 400),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
            decoration: BoxDecoration(
              color: _hover ? t.navHoverBg : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.chevron_left, size: 16, color: color),
                Icon(Icons.home_outlined, size: 15, color: color),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _IconAction extends StatefulWidget {
  const _IconAction({required this.icon, required this.tooltip, this.onTap});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  State<_IconAction> createState() => _IconActionState();
}

class _IconActionState extends State<_IconAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = GlimprTheme.of(context);
    final enabled = widget.onTap != null;
    final color = !enabled ? t.fg4 : (_hover ? t.fg1 : t.fg2);
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: enabled ? (_) => setState(() => _hover = true) : null,
      onExit: enabled ? (_) => setState(() => _hover = false) : null,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Tooltip(
          message: widget.tooltip,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: enabled && _hover ? t.navHoverBg : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(widget.icon, size: 18, color: color),
          ),
        ),
      ),
    );
  }
}

/// A compact icon+label action for the bottom bar. The accent variant fills with
/// the brand gradient (Save); the rest read as quiet glass actions (Open, Copy).
class _BarAction extends StatefulWidget {
  const _BarAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.accent = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool accent;

  @override
  State<_BarAction> createState() => _BarActionState();
}

class _BarActionState extends State<_BarAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = GlimprTheme.of(context);
    final enabled = widget.onTap != null;
    final accent = widget.accent;
    final fg = accent
        ? GlimprTokens.onAccent
        : (!enabled ? t.fg4 : (_hover ? t.fg1 : t.fg2));
    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        onEnter: enabled ? (_) => setState(() => _hover = true) : null,
        onExit: enabled ? (_) => setState(() => _hover = false) : null,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              gradient: accent ? GlimprTokens.accentGrad : null,
              color: accent
                  ? null
                  : (_hover && enabled ? t.navHoverBg : Colors.transparent),
              borderRadius: BorderRadius.circular(9),
              boxShadow: accent
                  ? [
                      BoxShadow(
                        color: t.shadowAccent,
                        blurRadius: 16,
                        offset: const Offset(0, 5),
                      ),
                    ]
                  : null,
            ),
            // Faint hover wash on the accent button (no movement), matching
            // [AccentButton]'s highlight model.
            foregroundDecoration: accent
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(9),
                    color: _hover && enabled
                        ? const Color(0x1FFFFFFF)
                        : const Color(0x00FFFFFF),
                  )
                : null,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.icon, size: 16, color: fg),
                const SizedBox(width: 7),
                Text(widget.label, style: GlimprType.sansStyle(13.5, 600, fg)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A recent-file tile on the landing grid: image-first cover thumbnail with a
/// one-line basename caption; name + full path show in the hover tooltip. Hover
/// gets the shared nav wash (accent stays reserved for active/selected chrome).
/// Right-click offers Show in Finder / Remove from Recent / Clear Recent.
class _RecentTile extends StatefulWidget {
  const _RecentTile({
    required this.path,
    required this.onTap,
    required this.onCopy,
    required this.onCopyPath,
    required this.onShare,
    required this.onPin,
    required this.onReveal,
    required this.onRemove,
    required this.onClear,
  });
  final String path;
  final VoidCallback onTap;
  final VoidCallback onCopy;
  final VoidCallback onCopyPath;
  final VoidCallback onShare;
  final VoidCallback onPin;
  final VoidCallback onReveal;
  final VoidCallback onRemove;
  final VoidCallback onClear;

  @override
  State<_RecentTile> createState() => _RecentTileState();
}

// One cache for every tile; survives gallery rebuilds and window hide/show.
final ThumbCache _thumbCache = ThumbCache();

class _RecentTileState extends State<_RecentTile> {
  bool _hover = false;
  // Held across rebuilds so a gallery refresh (windowBecameKey, capture saved)
  // never re-kicks the lookup; only a path change does.
  late Future<File?> _thumb = _thumbCache.obtain(widget.path);

  @override
  void didUpdateWidget(covariant _RecentTile old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) _thumb = _thumbCache.obtain(widget.path);
  }

  @override
  Widget build(BuildContext context) {
    final t = GlimprTheme.of(context);
    final name = p.basename(widget.path);
    // Tiles are dynamically sized now: Tooltip offsets from the TARGET CENTER,
    // so a fixed offset floats mid-tile on large tiles — anchor it just past
    // the cell's bottom edge instead (half the measured height + a margin).
    return LayoutBuilder(
      builder: (context, box) => MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        onSecondaryTapDown: (d) => _contextMenu(t, d.globalPosition),
        child: Tooltip(
          message: '$name\n${widget.path}',
          waitDuration: const Duration(milliseconds: 400),
          verticalOffset: box.maxHeight / 2 + 8,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: _hover ? t.navHoverBg : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
            ),
            // The tile fills its grid cell: the thumbnail takes all the
            // height the caption doesn't need.
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _thumbnail(t)),
                const SizedBox(height: 4),
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GlimprType.sansStyle(
                    8.5,
                    600,
                    _hover ? t.fg1 : t.fg3,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }

  /// The cover-fit file thumbnail, served from the persisted ThumbCache (a
  /// ~256px sidecar PNG) so the landing never decodes full-resolution sources
  /// (F1-3: 30 x 5K recents measured a ~578MB launch transient). Falls back
  /// to a direct bounded decode when the cache is unavailable, and to the
  /// generic image glyph when the file is unreadable. The inset backdrop
  /// shows through transparent PNGs.
  Widget _thumbnail(GlimprTokens t) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: t.insetBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.cardBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: FutureBuilder<File?>(
        future: _thumb,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            // Inset backdrop only while the cache resolves — no glyph flash.
            return const SizedBox.expand();
          }
          final file = snap.data ?? File(widget.path);
          return Image.file(
            file,
            fit: BoxFit.cover,
            // Top edge, not centre: window title bars / page headers are the
            // most recognisable slice of a tall screenshot.
            alignment: Alignment.topCenter,
            // Bounds the fallback's direct decode; a no-op for cache files.
            cacheHeight: 256,
            errorBuilder: (_, _, _) =>
                Icon(Icons.image_outlined, size: 18, color: t.fg3),
          );
        },
      ),
    );
  }

  /// Right-click menu, styled like the editor's Done chevron menu. The menu
  /// route lives in the app overlay, ABOVE the GlimprTheme scope — pass the
  /// tokens in rather than re-reading them there.
  Future<void> _contextMenu(GlimprTokens t, Offset at) async {
    final l = AppLocalizations.of(context);
    final action = await showMenu<VoidCallback>(
      context: context,
      // left < right and top < bottom anchor the menu's TOP-LEFT at the click,
      // so it always opens toward the bottom-right of the cursor (macOS feel);
      // the route still clamps it inside the window near the edges.
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx + 1, at.dy + 1),
      popUpAnimationStyle: AnimationStyle.noAnimation,
      color: t.hudBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(GlimprTokens.radiusMenu),
        side: BorderSide(color: t.hudBorder),
      ),
      items: [
        _menuItem(t, l.editorContextEdit, Icons.edit_outlined, widget.onTap),
        const PopupMenuDivider(height: 8),
        _menuItem(t, l.editorContextCopyImage, Icons.copy_outlined, widget.onCopy),
        _menuItem(t, l.editorContextCopyPath, Icons.link, widget.onCopyPath),
        // Share is macOS-only (no system share surface wired on Windows v1).
        if (!Platform.isWindows)
          _menuItem(t, l.editorContextShare, Icons.ios_share, widget.onShare),
        _menuItem(t, l.editorContextPinToScreen, Icons.push_pin_outlined, widget.onPin),
        _menuItem(t, l.editorContextShowInFinder, Icons.folder_outlined, widget.onReveal),
        const PopupMenuDivider(height: 8),
        _menuItem(
            t, l.editorContextRemoveFromRecent, Icons.close_outlined, widget.onRemove),
        _menuItem(
            t, l.editorContextClearRecent, Icons.delete_sweep_outlined, widget.onClear),
      ],
    );
    action?.call();
  }

  PopupMenuItem<VoidCallback> _menuItem(
          GlimprTokens t, String label, IconData icon, VoidCallback action) =>
      PopupMenuItem(
        value: action,
        height: 36,
        child: Row(
          children: [
            Icon(icon, size: 16, color: t.fg2),
            const SizedBox(width: 10),
            Text(label, style: GlimprType.sansStyle(13.5, 500, t.fg1)),
          ],
        ),
      );
}

/// Builds an Aurora-tinted confirmation [SnackBar] (floating, brand-bordered).
