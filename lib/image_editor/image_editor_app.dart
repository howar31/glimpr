import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path/path.dart' as p;
import '../editor/draw_style.dart';
import '../editor/document.dart';
import '../editor/editor_controller.dart';
import '../editor/editor_core.dart';
import '../editor/loupe_config.dart';
import '../editor/tool_style_store.dart';
import '../editor/viewport.dart';
import '../overlay/toolbar.dart';
import '../settings/settings.dart';
import '../settings/settings_mask.dart';
import '../shortcuts/hotkey_binding.dart';
import '../shortcuts/shortcut_actions.dart';
import '../shortcuts/shortcut_store.dart';
import '../theme/glimpr_controls.dart';
import '../theme/glimpr_theme.dart';
import 'checkerboard.dart';
import 'image_editor_export.dart';
import 'image_editor_host.dart';
import 'recent_images.dart';

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
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final ValueNotifier<({int id, Offset cursor})> _active = ValueNotifier(
    (id: ImageEditorHost.kImageEditorHostId, cursor: Offset.zero),
  );

  final Map<ToolKind, DrawStyle> _toolStyles = {};
  Timer? _persistTimer; // debounces saving _toolStyles to the shared store
  Map<String, HotkeyBinding?> _bindings = {...kDefaultBindings};
  LoupeConfig _loupe = const LoupeConfig();
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

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
      } else if (call.method == 'windowBecameKey') {
        // Returning to the editor (e.g. from Settings) picks up any change.
        if (mounted) setState(() => _windowActive = true);
        _reload();
      } else if (call.method == 'windowResignedKey') {
        if (mounted) setState(() => _windowActive = false);
      } else if (call.method == 'requestClose') {
        await _requestClose();
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
    late final Uint8List bytes;
    try {
      bytes = await File(path).readAsBytes();
    } catch (e) {
      _toast('Cannot read file: $e');
      return;
    }

    ui.Image img;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      img = frame.image;
      codec.dispose();
    } catch (e) {
      _toast('Cannot decode image: $e');
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
  Future<void> _recordRecent(String path) async {
    final store = _recentStore;
    if (store == null) return;
    try {
      await store.add(path);
    } catch (_) {
      return;
    }
    await _refreshRecent();
  }

  /// Reload the recent list, drop entries whose file is gone, then update the
  /// landing list and push the pruned list to the native "Open Recent" submenu.
  Future<void> _refreshRecent() async {
    final store = _recentStore;
    if (store == null) return;
    List<String> list;
    try {
      list = pruneMissing(await store.load(), (p) => File(p).existsSync());
    } catch (_) {
      return;
    }
    if (!mounted) return;
    setState(() => _recent = list);
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
      _dirty = false;
    });
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
    Uint8List? bytes;
    try {
      bytes = await Pasteboard.image;
    } catch (_) {
      return; // clipboard plugin unavailable (e.g. tests)
    }
    if (bytes == null) {
      _toast('No image in clipboard');
      return;
    }
    ui.Image img;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      img = frame.image;
      codec.dispose();
    } catch (e) {
      _toast('Cannot decode clipboard image');
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

  /// Hot-reload the settings that affect a live editor session: loupe geometry +
  /// the capture/output snapshot (`_cap`). Deliberately does NOT re-read
  /// in-session interaction state (the in-progress tool styles, the current
  /// tool / selection), so returning never clobbers what the user is doing.
  void _reload() {
    try {
      Settings.instance.loadLoupe().then((l) {
        if (mounted) setState(() => _loupe = l);
      }).catchError((_) {});
      Settings.instance.loadCapture().then((c) {
        if (mounted) setState(() => _cap = c);
      }).catchError((_) {});
    } catch (_) {}
  }

  /// Copy the annotated image to the clipboard.
  Future<void> _copy() => _export(saveToFile: false, copyToClipboard: true);

  /// Save the annotated image to the configured folder.
  Future<void> _save() => _export(saveToFile: true, copyToClipboard: false);

  /// Composite + deliver the annotated image and show a result toast. The shared
  /// [_exporting] guard covers both Copy and Save so rapid clicks don't re-fire.
  Future<void> _export({
    required bool saveToFile,
    required bool copyToClipboard,
  }) async {
    final baseImage = _image, controller = _controller;
    if (baseImage == null || controller == null || _exporting) return;
    setState(() => _exporting = true);
    try {
      final cap = _cap;
      // After a crop-trim the document carries the smaller canvas image; export
      // that (and the already-shifted drawables), else the untrimmed base.
      final doc = controller.document.value;
      final result = await exportImage(
        image: doc.canvasImage ?? baseImage,
        drawables: doc.drawables,
        jpeg: cap.isJpeg,
        jpegQuality: cap.jpegQuality,
        saveToFile: saveToFile,
        copyToClipboard: copyToClipboard,
        saveDir: cap.saveDir,
        sourceName: _sourceName,
      );
      if (!mounted) return;
      if (copyToClipboard) {
        _toast(result.copiedToClipboard
            ? 'Copied to clipboard'
            : 'Copy failed');
      } else {
        // Clear dirty only on a confirmed file save, not on clipboard copy.
        if (result.savedOk && mounted) setState(() => _dirty = false);
        _toast(result.savedOk
            ? 'Saved to ${result.savedPath}'
            : 'Save failed');
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// Aurora-styled "discard unsaved changes?" confirmation. Returns true to
  /// proceed (discard), false to cancel. Re-entrancy-guarded so two triggers
  /// (e.g. Cmd-W + Open) never stack dialogs.
  Future<bool> _confirmDiscard() async {
    final ctx = _navigatorKey.currentContext;
    if (ctx == null || _confirming) return false;
    _confirming = true;
    try {
      final brightness =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
      final t = GlimprTokens.forBrightness(brightness);
      final result = await showDialog<bool>(
        context: ctx,
        barrierColor: const Color(0x99000000),
        builder: (c) => GlimprTheme(
          tokens: t,
          child: Center(
            child: Material(
              type: MaterialType.transparency,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: BackdropFilter(
                    // Frosted glass matching the toolbar (blur + tint + border) so
                    // the dialog reads as a solid surface, not see-through.
                    filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                    child: Container(
                      padding: const EdgeInsets.all(22),
                      decoration: BoxDecoration(
                        color: brightness == Brightness.dark
                            ? const Color(0xF2161A24)
                            : const Color(0xF2EEF2F7),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: brightness == Brightness.dark
                              ? const Color(0x33FFFFFF)
                              : const Color(0x66FFFFFF),
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Discard changes?',
                            style: GlimprType.sansStyle(18, 700, t.fg1,
                                letterSpacing: -0.3),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'You have unsaved annotations. Discard them?',
                            style: GlimprType.sansStyle(13.5, 400, t.fg3,
                                height: 1.45),
                          ),
                          const SizedBox(height: 20),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              GhostButton('Cancel',
                                  onTap: () => Navigator.of(c).pop(false)),
                              const SizedBox(width: 10),
                              AccentButton('Discard',
                                  onTap: () => Navigator.of(c).pop(true)),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      return result ?? false;
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

  void _toast(String message) {
    _messengerKey.currentState
      ?..hideCurrentSnackBar()
      ..showSnackBar(_AuroraSnack.build(message));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _persistTimer?.cancel();
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
      scaffoldMessengerKey: _messengerKey,
      theme: ThemeData(
        brightness: brightness,
        scaffoldBackgroundColor: Colors.transparent,
        fontFamily: GlimprType.sans,
      ),
      home: GlimprTheme(
        tokens: tokens,
        child: Scaffold(
          backgroundColor: tokens.isDark
              ? const Color(0xFF0F1526)
              : const Color(0xFFEFF2F7),
          // A 44px Flutter title bar runs across the top in BOTH states (the OS
          // title is hidden + transparent), with the state content filling below.
          body: Stack(
            children: [
              Column(
                children: [
                  _titleBar(tokens),
                  Expanded(
                    child:
                        (image == null || bytes == null || controller == null)
                        ? _landing(tokens)
                        : _editor(tokens, image, bytes, controller),
                  ),
                ],
              ),
              // Dim + lock the editor while Settings is open and the editor
              // isn't the active window (correct regardless of open order).
              if (_showSettingsMask) const SettingsMask(),
            ],
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
        decoration: BoxDecoration(
          color: t.isDark
              ? const Color(0x99020617) // rgba(2,6,23,0.6)-ish translucent slab
              : const Color(0xCCFFFFFF),
          border: Border(
            bottom: BorderSide(
              color: t.isDark
                  ? const Color(0x1AFFFFFF) // rgba(255,255,255,0.1)
                  : const Color(0x140F172A),
            ),
          ),
        ),
        child: Row(
          children: [
            // Left inset to clear the macOS traffic-light buttons.
            const SizedBox(width: 78),
            // The Viewfinder logo mark (same as the Settings sidebar), replacing
            // the former decorative brand dot.
            const GlimprMark(size: 18),
            const SizedBox(width: 9),
            Text(
              'Image Editor',
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
        if (e is KeyDownEvent &&
            HardwareKeyboard.instance.isMetaPressed &&
            e.logicalKey == LogicalKeyboardKey.comma) {
          _openSettings(); // ⌘, works on the landing too (EditorCore unmounted)
          return KeyEventResult.handled;
        }
        if (e is KeyDownEvent &&
            HardwareKeyboard.instance.isMetaPressed &&
            e.logicalKey == LogicalKeyboardKey.keyV) {
          _pasteLoad();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: GlassCard.padded(
            pad: 36,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const GlimprMark(size: 56),
                const SizedBox(height: 22),
                Text(
                  'Open an image to edit',
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
                  'Annotate, crop, and re-export any image in the same toolkit '
                  'you use to capture.',
                  textAlign: TextAlign.center,
                  style: GlimprType.sansStyle(13, 400, t.fg3, height: 1.45),
                ),
                const SizedBox(height: 24),
                AccentButton(
                  'Open Image…',
                  icon: Icons.image_outlined,
                  onTap: _openPanel,
                ),
                const SizedBox(height: 12),
                Text(
                  'or drag an image here · paste with ⌘V',
                  textAlign: TextAlign.center,
                  style: GlimprType.sansStyle(11.5, 500, t.fg4),
                ),
                _recentList(t),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Recent-files list shown on the landing card (up to 5). Tapping a row loads
  /// that file; renders nothing when the list is empty.
  Widget _recentList(GlimprTokens t) {
    if (_recent.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 22),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Recent',
            style: GlimprType.sansStyle(11, 700, t.fg4, letterSpacing: 0.4),
          ),
        ),
        const SizedBox(height: 6),
        for (final path in _recent.take(5))
          _RecentRow(path: path, onTap: () => _loadPath(path)),
      ],
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
          child: Center(child: _toolbarPill(controller)),
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
      onComplete: _save,
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
  Widget _toolbarPill(EditorController controller) {
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
            tooltip: 'Fit to window (⌘1)',
            onTap: _viewport.fit,
          ),
          _IconAction(
            icon: Icons.crop_free,
            tooltip: 'Actual size · 100% (⌘2)',
            onTap: _viewport.actualSize,
          ),
          const SizedBox(width: 8),
          _HistoryButtons(controller: controller),
          const SizedBox(width: 8),
          _BarAction(
            icon: Icons.folder_open_outlined,
            label: 'Open',
            onTap: _openPanel,
          ),
          const SizedBox(width: 4),
          _BarAction(
            icon: Icons.copy_outlined,
            label: 'Copy',
            onTap: _exporting ? null : _copy,
          ),
          const SizedBox(width: 4),
          _BarAction(
            icon: Icons.save_outlined,
            label: 'Save',
            accent: true,
            onTap: _exporting ? null : _save,
          ),
        ],
      );
  }
}

/// Undo / redo icon pair styled to sit inside the toolbar's glass bar, enabled
/// per the document's [EditorDocument.canUndo] / [EditorDocument.canRedo].
class _HistoryButtons extends StatelessWidget {
  const _HistoryButtons({required this.controller});
  final EditorController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<EditorDocument>(
      valueListenable: controller.document,
      builder: (_, doc, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _IconAction(
            icon: Icons.undo,
            tooltip: 'Undo',
            onTap: doc.canUndo ? controller.undo : null,
          ),
          _IconAction(
            icon: Icons.redo,
            tooltip: 'Redo',
            onTap: doc.canRedo ? controller.redo : null,
          ),
        ],
      ),
    );
  }
}

/// A compact icon-only action button matching the toolbar's foreground palette.
/// Dims when [onTap] is null.
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

/// A tappable recent-file row on the landing card: image glyph + basename over a
/// dim full path, with a hover wash matching the bar actions.
class _RecentRow extends StatefulWidget {
  const _RecentRow({required this.path, required this.onTap});
  final String path;
  final VoidCallback onTap;

  @override
  State<_RecentRow> createState() => _RecentRowState();
}

class _RecentRowState extends State<_RecentRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = GlimprTheme.of(context);
    final name = p.basename(widget.path);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          margin: const EdgeInsets.only(bottom: 2),
          decoration: BoxDecoration(
            color: _hover ? t.navHoverBg : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(Icons.image_outlined, size: 15, color: t.fg3),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GlimprType.sansStyle(13, 600, t.fg2),
                    ),
                    Text(
                      widget.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: GlimprType.sansStyle(10.5, 400, t.fg4),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Builds an Aurora-tinted confirmation [SnackBar] (floating, brand-bordered).
class _AuroraSnack {
  static SnackBar build(String message) => SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xF21A2236),
        elevation: 8,
        duration: const Duration(milliseconds: 2200),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0x3360A5FA)),
        ),
        content: Text(
          message,
          style: GlimprType.sansStyle(13.5, 600, const Color(0xF2FFFFFF)),
        ),
      );
}
