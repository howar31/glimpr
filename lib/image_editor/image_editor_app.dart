import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../editor/draw_style.dart';
import '../editor/document.dart';
import '../editor/editor_controller.dart';
import '../editor/editor_core.dart';
import '../editor/tool_style_store.dart';
import '../overlay/toolbar.dart';
import '../settings/settings.dart';
import '../shortcuts/hotkey_binding.dart';
import '../shortcuts/shortcut_actions.dart';
import '../shortcuts/shortcut_store.dart';
import '../theme/glimpr_controls.dart';
import '../theme/glimpr_theme.dart';
import 'checkerboard.dart';
import 'image_editor_export.dart';
import 'image_editor_host.dart';

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
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final ValueNotifier<({int id, Offset cursor})> _active = ValueNotifier(
    (id: ImageEditorHost.kImageEditorHostId, cursor: Offset.zero),
  );

  final Map<ToolKind, DrawStyle> _toolStyles = {};
  Map<String, HotkeyBinding?> _bindings = {...kDefaultBindings};
  CaptureSettings _cap = CaptureSettings.defaults;

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

    // The native side sends 'loadPath' or 'requestClose' via the editor channel.
    // loadPath: user picked a file via the system Open panel (or Finder "Open With").
    // requestClose: a close gesture (red button / Cmd-W) was intercepted natively;
    // Dart runs the dirty-check dialog and, if the user confirms, calls hideEditor.
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'loadPath') {
        final path = call.arguments as String?;
        if (path != null) await _loadPath(path);
      } else if (call.method == 'requestClose') {
        await _requestClose();
      }
    });
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
    try {
      final path = await _channel.invokeMethod<String>('openPanel');
      if (path != null && mounted) await _loadPath(path);
    } catch (_) {
      // Channel unavailable (e.g. test environment) or user cancelled — ignore.
    }
  }

  /// Read, decode, and show [path] in the editor.
  Future<void> _loadPath(String path) async {
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
    setState(() {
      _image?.dispose();
      _image = img;
      _bytes = bytes;
      _sourceName = p.basenameWithoutExtension(path);
      _controller?.dispose();
      _controller = EditorController(toolStyles: _toolStyles);
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
    final image = _image, controller = _controller;
    if (image == null || controller == null || _exporting) return;
    setState(() => _exporting = true);
    try {
      final cap = _cap;
      final result = await exportImage(
        image: image,
        drawables: controller.document.value.drawables,
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

  /// Handle a close gesture from native (red button or Cmd-W). If the image has
  /// unsaved annotations, shows a confirmation dialog; on confirm (or when clean)
  /// calls [_closeAndReset] which hides the window and unloads the image.
  Future<void> _requestClose() async {
    // Guard against re-entrancy (e.g. Cmd-W pressed twice) so we never stack two
    // confirm dialogs or run two resets.
    if (_closePending) return;
    _closePending = true;
    try {
      if (_dirty && _image != null) {
        final ctx = _navigatorKey.currentContext;
        final discard = ctx == null
            ? true
            : await showDialog<bool>(
                context: ctx,
                builder: (c) => AlertDialog(
                  title: const Text('Discard changes?'),
                  content: const Text(
                      'You have unsaved annotations. Close without saving?'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.of(c).pop(false),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: () => Navigator.of(c).pop(true),
                        child: const Text('Discard')),
                  ],
                ),
              );
        if (discard != true) return;
      }
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
    _image?.dispose();
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
          body: Column(
            children: [
              _titleBar(tokens),
              Expanded(
                child: (image == null || bytes == null || controller == null)
                    ? _landing(tokens)
                    : _editor(tokens, image, bytes, controller),
              ),
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
    return Container(
      height: 44,
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
          Container(
            width: 7,
            height: 7,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: kGlimprLogoGradient, // match the wordmark's brand gradient
            ),
          ),
          const SizedBox(width: 9),
          Text(
            'Image Editor',
            style: GlimprType.sansStyle(13, 600, t.fg2, letterSpacing: -0.1),
          ),
        ],
      ),
    );
  }

  /// Landing state: an Aurora card prompting the user to open an image. Paste /
  /// drag-drop / Open Recent are later blocks — only the static hint + the Open
  /// button are wired now.
  Widget _landing(GlimprTokens t) {
    return Center(
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
                style: GlimprType.sansStyle(18, 700, t.fg1, letterSpacing: -0.3),
              ),
              const SizedBox(height: 8),
              Text(
                'Annotate, crop, and re-export any image in the same toolkit you '
                'use to capture.',
                textAlign: TextAlign.center,
                style: GlimprType.sansStyle(13, 400, t.fg3, height: 1.45),
              ),
              const SizedBox(height: 24),
              AccentButton(
                'Open Image…',
                icon: Icons.image_outlined,
                onTap: _openPanel,
              ),
            ],
          ),
        ),
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
          child: Center(child: _toolbarPill(controller)),
        ),
      ],
    );
  }

  /// The canvas area: a checkerboard transparency backdrop with the fitted,
  /// drop-shadowed [EditorCore] centred inside it. The image fits within ~72% of
  /// the canvas width (and the available height) so it never crowds the edges or
  /// the floating toolbar pill, and its drop shadow is never clipped.
  Widget _canvas(
    GlimprTokens t,
    ui.Image image,
    Uint8List bytes,
    EditorController controller,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const inset = 28.0; // breathing room so the shadow isn't clipped
        // Reserve room at the bottom for the floating pill (its bar + option
        // row sit ~18px from the bottom) so the image stays clear of it.
        const bottomReserve = 110.0;
        final availW = (constraints.maxWidth * 0.72)
            .clamp(1.0, double.infinity);
        final availH =
            (constraints.maxHeight - inset * 2 - bottomReserve)
                .clamp(1.0, double.infinity);
        final imgW = image.width.toDouble(), imgH = image.height.toDouble();
        // Fit within the width budget AND the height budget, never upscaling.
        final scale = (availW / imgW).clamp(0.0, availH / imgH).clamp(0.0, 1.0);
        final fitted = Size(imgW * scale, imgH * scale);
        final host = ImageEditorHost(
          image: image,
          bytes: bytes,
          fittedSize: fitted,
          onComplete: _save,
          activeSignal: _active,
        );
        return Stack(
          fit: StackFit.expand,
          children: [
            Checkerboard(dark: t.isDark),
            Center(
              child: Container(
                width: fitted.width,
                height: fitted.height,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: const Color(0x14FFFFFF), // 1px rgba(255,255,255,0.08)
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x8C000000), // rgba(0,0,0,0.55)
                      blurRadius: 70,
                      offset: Offset(0, 30),
                    ),
                  ],
                ),
                // Clip the EditorCore to the rounded frame so the corners match
                // the border; the shadow lives outside the clip (on the parent).
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: EditorCore(
                    key: ValueKey(image), // fresh State per loaded image
                    controller: controller,
                    editorBindings: _bindings,
                    host: host,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// The floating toolbar pill: the shared [EditorToolbar] (no drag handle, not
  /// draggable) with undo/redo + Open/Copy/Save as trailing actions inside its
  /// own glass bar. Its contextual option row grows UPWARD above the bar, over
  /// the canvas. No wrapping background — the pill IS the toolbar's glass bar.
  Widget _toolbarPill(EditorController controller) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: EditorToolbar(
        controller: controller,
        editorBindings: _bindings,
        showDragHandle: false,
        onMove: (_) {}, // fixed — not draggable
        onPtEditingDone: () {}, // focus refinement is a later 微調
        trailing: [
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
      ),
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
