import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../image_editor/checkerboard.dart';
import '../l10n/gen/app_localizations.dart';
import '../platform_gate.dart';
import '../settings/app_locale.dart';
import '../theme/glimpr_controls.dart';
import '../theme/glimpr_theme.dart';
import 'export_service.dart';
import 'frame_store.dart';
import 'gif_document.dart';
import 'gif_editor_controller.dart';

/// Standalone GIF Editor window (the third editor surface, next to the
/// Settings window and the Image Editor). Same Aurora chrome recipe as the
/// Image Editor: native vibrancy behind a transparent scaffold on macOS with
/// a 44px Flutter title bar; opaque winBase + OS caption on Windows.
///
/// S1 scope: landing card -> open a GIF -> frame timeline with playback and
/// stats -> pass-through GIF export. Frame editing operations arrive in
/// later slices; the editing MODEL here is a frame sequence, deliberately
/// separate from the Image Editor's single-canvas annotation model.
class GifEditorApp extends StatefulWidget {
  const GifEditorApp({super.key, this.controller});

  /// Test seam: widget tests inject a preloaded controller so the heavy
  /// open path (real IO + engine decode) can run under runAsync first.
  final GifEditorController? controller;

  @override
  State<GifEditorApp> createState() => _GifEditorAppState();
}

class _GifEditorAppState extends State<GifEditorApp>
    with WidgetsBindingObserver {
  // Resolved from a context inside the MaterialApp's Localizations scope
  // (same field pattern as the Image Editor).
  late AppLocalizations _l;

  static const _channel = MethodChannel('glimpr/gifEditor');

  late final GifEditorController _c;
  late final bool _ownsController;
  final ScrollController _strip = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ownsController = widget.controller == null;
    _c = widget.controller ?? GifEditorController();
    _c.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _c.removeListener(_onControllerChanged);
    if (_ownsController) _c.dispose();
    _strip.dispose();
    _loopField.dispose();
    _delayField.dispose();
    _resizeW.dispose();
    _resizeH.dispose();
    _toastTimer?.cancel();
    _toastClearTimer?.cancel();
    super.dispose();
  }

  void _onControllerChanged() => setState(_seedOptions);

  @override
  void didChangePlatformBrightness() => setState(() {});

  // Basename of the opened file; seeds the export save panel's suggestion.
  String _sourceName = 'animation';
  bool _exporting = false;
  double _exportProgress = 0;

  // Export options (session state; the loop fields re-seed per document).
  PaletteStrategy _optStrategy = PaletteStrategy.global;
  bool _optDither = false;
  bool _optOptimize = true;
  bool _optLoopForever = true;
  int _optLoopCount = 1;
  bool _optionsOpen = false;
  final TextEditingController _loopField = TextEditingController(text: '1');
  GifDocument? _seededDoc;

  // Timeline panels (delay / reduce / resize) share the popover surface; at
  // most one of them (or the export options popover) is open at a time.
  _TimelinePanel _panel = _TimelinePanel.none;
  _DelayMode _delayMode = _DelayMode.set;
  final TextEditingController _delayField =
      TextEditingController(text: '100');
  int _reduceN = 2;

  // Resize panel state (fields re-seed from the document when it opens).
  final TextEditingController _resizeW = TextEditingController();
  final TextEditingController _resizeH = TextEditingController();
  bool _resizeLock = true;

  // Crop mode: the rect lives in IMAGE pixel coordinates.
  bool _cropMode = false;
  Rect? _cropRect;

  void _closePanels() {
    _optionsOpen = false;
    _panel = _TimelinePanel.none;
    _cropMode = false;
    _cropRect = null;
  }

  void _toggleCropMode() {
    setState(() {
      final was = _cropMode;
      _closePanels();
      _cropMode = !was;
      if (_cropMode) _c.pause();
    });
  }

  void _applyCrop() {
    final r = _cropRect;
    if (r == null) return;
    final x = r.left.round();
    final y = r.top.round();
    final w = r.right.round() - x;
    final h = r.bottom.round() - y;
    setState(_closePanels);
    if (w >= 1 && h >= 1) {
      unawaited(_c.cropDoc(x, y, w, h));
    }
  }

  /// Aspect-locked companion update: editing one resize field rewrites the
  /// other from the document's ratio (programmatic .text changes do not
  /// re-enter onChanged).
  void _resizeFieldEdited({required bool widthEdited}) {
    if (!_resizeLock) return;
    final doc = _c.doc;
    if (doc == null) return;
    final iw = doc.frames.first.width;
    final ih = doc.frames.first.height;
    if (widthEdited) {
      final w = int.tryParse(_resizeW.text);
      if (w != null && w > 0) {
        _resizeH.text = '${(w * ih / iw).round().clamp(1, 16384)}';
      }
    } else {
      final h = int.tryParse(_resizeH.text);
      if (h != null && h > 0) {
        _resizeW.text = '${(h * iw / ih).round().clamp(1, 16384)}';
      }
    }
  }

  /// Re-seed the loop option from each newly opened document (the other
  /// options are sticky for the window's lifetime).
  void _seedOptions() {
    final doc = _c.doc;
    if (identical(doc, _seededDoc)) return;
    _seededDoc = doc;
    _closePanels();
    if (doc != null) {
      _optLoopForever = doc.loopCount == 0;
      _optLoopCount = doc.loopCount == 0 ? 1 : doc.loopCount;
      _loopField.text = '$_optLoopCount';
    }
  }

  /// File picker; macOS uses the native NSOpenPanel (openPanel channel
  /// method), Windows the cross-platform file_selector dialog (the runner
  /// hosts no dialogs — same split as the Image Editor).
  Future<void> _openPanel() async {
    if (_c.opening) return;
    String? path;
    if (platformIsWindows) {
      const group = XTypeGroup(label: 'GIF', extensions: ['gif']);
      path = (await openFile(acceptedTypeGroups: [group]))?.path;
    } else {
      path = await _channel.invokeMethod<String>('openPanel');
    }
    if (path == null || path.isEmpty || !mounted) return;
    try {
      final bytes = await File(path).readAsBytes();
      await _c.openBytes(bytes);
      final base = path.split(Platform.pathSeparator).last;
      final dot = base.lastIndexOf('.');
      _sourceName = dot > 0 ? base.substring(0, dot) : base;
    } catch (_) {
      _toast(_l.gifEditorOpenFailed);
    }
  }

  Future<void> _export() async {
    final doc = _c.doc;
    final store = _c.store;
    if (doc == null || store == null || _exporting || _c.transforming) {
      return;
    }
    final suggested = '$_sourceName-edited.gif';
    String? out;
    if (platformIsWindows) {
      const group = XTypeGroup(label: 'GIF', extensions: ['gif']);
      out = (await getSaveLocation(
              suggestedName: suggested, acceptedTypeGroups: [group]))
          ?.path;
    } else {
      out = await _channel
          .invokeMethod<String>('savePanel', {'suggestedName': suggested});
    }
    if (out == null || out.isEmpty || !mounted) return;
    _c.pause();
    setState(() {
      _exporting = true;
      _exportProgress = 0;
    });
    // Tray processing pulse, parallel to the Image Editor's Done flow.
    unawaited(_channel.invokeMethod('setProcessing',
        {'active': true, 'label': _l.gifEditorExportButton}));
    try {
      await exportGif(
        doc: doc,
        store: store,
        outPath: out,
        options: GifExportOptions(
          strategy: _optStrategy,
          dither: _optDither,
          optimize: _optOptimize,
          loopCount: _optLoopForever ? 0 : _optLoopCount.clamp(1, 0xFFFF),
        ),
        onProgress: (done, total) =>
            setState(() => _exportProgress = done / total),
      );
      _toast(_l.gifEditorExportDone);
    } catch (_) {
      _toast(_l.gifEditorExportFailed);
    } finally {
      setState(() => _exporting = false);
      unawaited(
          _channel.invokeMethod('setProcessing', {'active': false}));
    }
  }

  // Top-centred toast pill, same idiom as the Image Editor's.
  String? _toastMsg;
  bool _toastVisible = false;
  Timer? _toastTimer;
  Timer? _toastClearTimer;

  void _toast(String msg) {
    _toastTimer?.cancel();
    _toastClearTimer?.cancel();
    setState(() {
      _toastMsg = msg;
      _toastVisible = true;
    });
    _toastTimer = Timer(const Duration(milliseconds: 2600), () {
      if (!mounted) return;
      setState(() => _toastVisible = false);
      _toastClearTimer = Timer(const Duration(milliseconds: 240), () {
        if (mounted) setState(() => _toastMsg = null);
      });
    });
  }

  void _requestClose() {
    _channel.invokeMethod('hideEditor');
  }

  /// Back to the landing: drop the current document (S1 has no dirty state
  /// to confirm; the frame store is disposed by the controller).
  void _goHome() => _c.close();

  // Windows only: push the localized title to the OS caption (no Flutter
  // title bar there; the runner C++ is ASCII-only and owns no l10n strings).
  String? _sentWindowTitle;

  void _syncWindowTitle() {
    if (!platformIsWindows) return;
    final title = _l.gifEditorTitleBar;
    if (title == _sentWindowTitle) return;
    _sentWindowTitle = title;
    try {
      _channel.invokeMethod('setWindowTitle', title);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final brightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    final tokens = GlimprTokens.forBrightness(brightness);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
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
        child: CallbackShortcuts(
          bindings: {
            if (platformIsWindows)
              const SingleActivator(LogicalKeyboardKey.keyW, control: true):
                  _requestClose,
            // Open a (new) GIF from anywhere; S1 has no dirty state so the
            // current document is simply replaced.
            SingleActivator(LogicalKeyboardKey.keyO,
                meta: !platformIsWindows,
                control: platformIsWindows): () => unawaited(_openPanel()),
            const SingleActivator(LogicalKeyboardKey.space): () {
              if (_c.doc != null) _c.togglePlay();
            },
            // Timeline editing (all no-ops on the landing).
            SingleActivator(LogicalKeyboardKey.keyZ,
                meta: !platformIsWindows,
                control: platformIsWindows): _c.undo,
            SingleActivator(LogicalKeyboardKey.keyZ,
                shift: true,
                meta: !platformIsWindows,
                control: platformIsWindows): _c.redo,
            SingleActivator(LogicalKeyboardKey.keyA,
                meta: !platformIsWindows,
                control: platformIsWindows): _c.selectAll,
            SingleActivator(LogicalKeyboardKey.keyX,
                meta: !platformIsWindows,
                control: platformIsWindows): _c.cutSelected,
            SingleActivator(LogicalKeyboardKey.keyC,
                meta: !platformIsWindows,
                control: platformIsWindows): _c.copySelected,
            SingleActivator(LogicalKeyboardKey.keyV,
                meta: !platformIsWindows,
                control: platformIsWindows): _c.pasteFrames,
            const SingleActivator(LogicalKeyboardKey.delete):
                _c.deleteSelected,
            const SingleActivator(LogicalKeyboardKey.backspace):
                _c.deleteSelected,
            // Crop mode commits on Enter; Escape backs out of any panel.
            const SingleActivator(LogicalKeyboardKey.enter): () {
              if (_cropMode) _applyCrop();
            },
            const SingleActivator(LogicalKeyboardKey.escape): () {
              if (_cropMode ||
                  _optionsOpen ||
                  _panel != _TimelinePanel.none) {
                setState(_closePanels);
              }
            },
          },
          child: Focus(
            // Shortcuts need a focused subtree; the canvas has no focusable
            // field of its own yet.
            autofocus: true,
            child: Scaffold(
            // Windows paints the opaque themed base (winBase rule); macOS
            // stays pure native vibrancy.
            backgroundColor:
                platformIsWindows ? tokens.winBase : Colors.transparent,
            body: Builder(
              builder: (ctx) {
                _l = AppLocalizations.of(ctx);
                _syncWindowTitle();
                return Stack(
                  children: [
                    Column(
                      children: [
                        // The Flutter title bar is macOS-only (frameless
                        // .fullSizeContentView chrome); Windows keeps the
                        // standard OS caption.
                        if (!platformIsWindows) _titleBar(tokens),
                        Expanded(
                          child: _c.doc == null
                              ? _landing(tokens)
                              : _editor(tokens),
                        ),
                      ],
                    ),
                    // Windows: a floating glass Home button at the canvas
                    // top-left while a GIF is loaded (the OS caption has no
                    // Flutter title bar to host one).
                    if (platformIsWindows && _c.doc != null)
                      Positioned(
                        top: 12,
                        left: 12,
                        child: _FloatingHomeButton(
                            key: const Key('gif-home'), onTap: _goHome),
                      ),
                    // Anchored panels (export options / delay / reduce)
                    // share one outside-tap barrier.
                    if ((_optionsOpen || _panel != _TimelinePanel.none) &&
                        _c.doc != null) ...[
                      Positioned.fill(
                        child: GestureDetector(
                          key: const Key('gif-options-barrier'),
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setState(_closePanels),
                        ),
                      ),
                      if (_optionsOpen) _optionsPopover(tokens),
                      if (_panel == _TimelinePanel.delay)
                        _delayPanel(tokens),
                      if (_panel == _TimelinePanel.reduce)
                        _reducePanel(tokens),
                      if (_panel == _TimelinePanel.resize)
                        _resizePanel(tokens),
                    ],
                    _toastLayer(tokens),
                  ],
                );
              },
            ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _titleBar(GlimprTokens t) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onDoubleTap: () => _channel.invokeMethod('titleBarDoubleClick'),
      child: Container(
        // Content centres against the native traffic lights (Image Editor
        // recipe: 32px puts the row centre at 16px).
        height: 32,
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: t.divider)),
        ),
        child: Row(
          children: [
            const SizedBox(width: 78), // clear the traffic-light buttons
            // Back to the landing (open another GIF) — same top-left home
            // idiom as the Image Editor; landing has nowhere to go back to.
            if (_c.doc != null) ...[
              _TitleBarHome(key: const Key('gif-home'), onTap: _goHome),
              const SizedBox(width: 6),
            ],
            const GlimprMark(size: 18),
            const SizedBox(width: 9),
            Text(
              _l.gifEditorTitleBar,
              style:
                  GlimprType.sansStyle(13, 600, t.fg2, letterSpacing: -0.1),
            ),
          ],
        ),
      ),
    );
  }

  Widget _landing(GlimprTokens t) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: GlassCard.padded(
          pad: 36,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const GlimprMark(size: 56),
              const SizedBox(height: 22),
              Text(
                _l.gifEditorOpenGif,
                textAlign: TextAlign.center,
                style:
                    GlimprType.sansStyle(18, 700, t.fg1, letterSpacing: -0.3),
              ),
              const SizedBox(height: 8),
              Text(
                _l.gifEditorOpenGifSubtitle,
                textAlign: TextAlign.center,
                style: GlimprType.sansStyle(13, 400, t.fg3, height: 1.45),
              ),
              const SizedBox(height: 24),
              _c.opening
                  ? Text(
                      _l.gifEditorImporting,
                      style: GlimprType.sansStyle(12.5, 500, t.fg3),
                    )
                  : AccentButton(
                      _l.gifEditorOpenGifButton,
                      icon: Icons.gif_box_outlined,
                      onTap: _openPanel,
                    ),
            ],
          ),
        ),
      ),
    );
  }

  /// Loaded state: preview canvas over a checkerboard, a controls/stats row,
  /// and the frame filmstrip along the bottom.
  Widget _editor(GlimprTokens t) {
    final doc = _c.doc!;
    final store = _c.store!;
    final frame = doc.frames[_c.current];
    return Column(
      key: const Key('gif-editor-canvas'),
      children: [
        Expanded(
          child: Stack(
            children: [
              Positioned.fill(child: Checkerboard(dark: t.isDark)),
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: _cropMode
                      ? _CropOverlay(
                          store: store,
                          frame: frame,
                          rect: _cropRect,
                          onRectChanged: (r) =>
                              setState(() => _cropRect = r),
                          onApply: _applyCrop,
                          onCancel: () => setState(_closePanels),
                        )
                      : _FramePreview(store: store, frame: frame),
                ),
              ),
            ],
          ),
        ),
        _controlsRow(t, doc),
        _opsRow(t, doc),
        _filmstrip(t, doc, store),
      ],
    );
  }

  /// Timeline editing toolbar: history, clipboard, frame and delay ops.
  Widget _opsRow(GlimprTokens t, GifDocument doc) {
    final busy = _c.transforming || _exporting;
    final sel = _c.selection;
    final hasSel = sel.isNotEmpty && !busy;
    final many = doc.frameCount >= 2 && !busy;
    final deletable =
        sel.isNotEmpty && sel.length < doc.frameCount && !busy;
    Widget divider() => Container(
          width: 1,
          height: 18,
          margin: const EdgeInsets.symmetric(horizontal: 6),
          color: t.divider,
        );
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: t.divider)),
      ),
      child: Row(
        children: [
          // The button strip scrolls when the window is narrower than the
          // full set; the status text stays pinned on the right.
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
          _OpButton(
            key: const Key('gif-op-undo'),
            icon: Icons.undo_rounded,
            tooltip: _l.gifEditorUndo,
            enabled: _c.canUndo && !busy,
            onTap: _c.undo,
          ),
          _OpButton(
            key: const Key('gif-op-redo'),
            icon: Icons.redo_rounded,
            tooltip: _l.gifEditorRedo,
            enabled: _c.canRedo && !busy,
            onTap: _c.redo,
          ),
          divider(),
          _OpButton(
            key: const Key('gif-op-cut'),
            icon: Icons.content_cut_rounded,
            tooltip: _l.gifEditorCut,
            enabled: deletable,
            onTap: _c.cutSelected,
          ),
          _OpButton(
            key: const Key('gif-op-copy'),
            icon: Icons.content_copy_rounded,
            tooltip: _l.gifEditorCopy,
            enabled: hasSel,
            onTap: _c.copySelected,
          ),
          _OpButton(
            key: const Key('gif-op-paste'),
            icon: Icons.content_paste_rounded,
            tooltip: _l.gifEditorPaste,
            enabled: _c.clipboardHasFrames && !busy,
            onTap: _c.pasteFrames,
          ),
          divider(),
          _OpButton(
            key: const Key('gif-op-delete'),
            icon: Icons.delete_outline_rounded,
            tooltip: _l.gifEditorDeleteFrames,
            enabled: deletable,
            onTap: _c.deleteSelected,
          ),
          _OpButton(
            key: const Key('gif-op-left'),
            icon: Icons.arrow_back_rounded,
            tooltip: _l.gifEditorMoveLeft,
            enabled: hasSel,
            onTap: () => _c.moveSelected(-1),
          ),
          _OpButton(
            key: const Key('gif-op-right'),
            icon: Icons.arrow_forward_rounded,
            tooltip: _l.gifEditorMoveRight,
            enabled: hasSel,
            onTap: () => _c.moveSelected(1),
          ),
          divider(),
          _OpButton(
            key: const Key('gif-op-reverse'),
            icon: Icons.swap_horiz_rounded,
            tooltip: _l.gifEditorReverse,
            enabled: many,
            onTap: _c.reverse,
          ),
          _OpButton(
            key: const Key('gif-op-yoyo'),
            icon: Icons.sync_alt_rounded,
            tooltip: _l.gifEditorYoyo,
            enabled: many,
            onTap: _c.yoyo,
          ),
          _OpButton(
            key: const Key('gif-op-dedupe'),
            icon: Icons.layers_clear_rounded,
            tooltip: _l.gifEditorRemoveDuplicates,
            enabled: many,
            onTap: _c.removeDuplicates,
          ),
          _OpButton(
            key: const Key('gif-op-reduce'),
            icon: Icons.compress_rounded,
            tooltip: _l.gifEditorReduceFrames,
            enabled: many,
            active: _panel == _TimelinePanel.reduce,
            onTap: () => setState(() {
              final open = _panel == _TimelinePanel.reduce;
              _closePanels();
              if (!open) _panel = _TimelinePanel.reduce;
            }),
          ),
          _OpButton(
            key: const Key('gif-op-delay'),
            icon: Icons.timer_outlined,
            tooltip: _l.gifEditorDelay,
            enabled: !busy,
            active: _panel == _TimelinePanel.delay,
            onTap: () => setState(() {
              final open = _panel == _TimelinePanel.delay;
              _closePanels();
              if (!open) _panel = _TimelinePanel.delay;
            }),
          ),
          divider(),
          _OpButton(
            key: const Key('gif-op-crop'),
            icon: Icons.crop_rounded,
            tooltip: _l.gifEditorCrop,
            enabled: !busy,
            active: _cropMode,
            onTap: _toggleCropMode,
          ),
          _OpButton(
            key: const Key('gif-op-resize'),
            icon: Icons.aspect_ratio_rounded,
            tooltip: _l.gifEditorResize,
            enabled: !busy,
            active: _panel == _TimelinePanel.resize,
            onTap: () => setState(() {
              final open = _panel == _TimelinePanel.resize;
              _closePanels();
              if (!open) {
                _panel = _TimelinePanel.resize;
                _resizeW.text = '${doc.frames.first.width}';
                _resizeH.text = '${doc.frames.first.height}';
              }
            }),
          ),
          _OpButton(
            key: const Key('gif-op-flip-h'),
            icon: Icons.flip_rounded,
            tooltip: _l.gifEditorFlipH,
            enabled: !busy,
            onTap: () => unawaited(_c.flipDoc(horizontal: true)),
          ),
          _OpButton(
            key: const Key('gif-op-flip-v'),
            icon: Icons.flip_camera_android_rounded,
            tooltip: _l.gifEditorFlipV,
            enabled: !busy,
            onTap: () => unawaited(_c.flipDoc(horizontal: false)),
          ),
          _OpButton(
            key: const Key('gif-op-rotate-left'),
            icon: Icons.rotate_90_degrees_ccw_rounded,
            tooltip: _l.gifEditorRotateLeft,
            enabled: !busy,
            onTap: () => unawaited(_c.rotateDoc(-1)),
          ),
          _OpButton(
            key: const Key('gif-op-rotate-right'),
            icon: Icons.rotate_90_degrees_cw_rounded,
            tooltip: _l.gifEditorRotateRight,
            enabled: !busy,
            onTap: () => unawaited(_c.rotateDoc(1)),
          ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          if (_c.transforming)
            Text(
              '${_l.gifEditorProcessing} '
              '${(_c.transformProgress * 100).round()}%',
              style: GlimprType.sansStyle(11.5, 500, t.fg3),
            )
          else if (sel.isNotEmpty)
            Text(
              _l.gifEditorSelectedCount(sel.length, doc.frameCount),
              style: GlimprType.sansStyle(11.5, 500, t.fg3),
            ),
        ],
      ),
    );
  }

  /// Resize panel (width / height with an aspect lock).
  Widget _resizePanel(GlimprTokens t) {
    Widget field(String label, Key key, TextEditingController ctrl,
            {required bool isWidth}) =>
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: GlimprType.sansStyle(12, 500, t.fg3)),
            const SizedBox(width: 6),
            SizedBox(
              width: 64,
              child: TextField(
                key: key,
                controller: ctrl,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(5),
                ],
                textAlign: TextAlign.center,
                style: GlimprType.sansStyle(12.5, 600, t.fg1),
                decoration: _fieldDecoration(t),
                onChanged: (_) => _resizeFieldEdited(widthEdited: isWidth),
              ),
            ),
          ],
        );

    return Positioned(
      left: 12,
      bottom: 86 + 40 + 8,
      child: Container(
        key: const Key('gif-resize-panel'),
        width: 332,
        padding: const EdgeInsets.fromLTRB(16, 13, 16, 16),
        decoration: _panelDecoration(t),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_l.gifEditorResize,
                style: GlimprType.sansStyle(11.5, 600, t.fg3,
                    letterSpacing: 0.2)),
            const SizedBox(height: 10),
            Row(
              children: [
                field(_l.gifEditorWidth, const Key('gif-resize-w'),
                    _resizeW,
                    isWidth: true),
                const SizedBox(width: 12),
                field(_l.gifEditorHeight, const Key('gif-resize-h'),
                    _resizeH,
                    isWidth: false),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(_l.gifEditorKeepAspect,
                      style: GlimprType.sansStyle(12.5, 500, t.fg2)),
                ),
                GlassToggle(
                  key: const Key('gif-resize-lock'),
                  value: _resizeLock,
                  onChanged: (v) => setState(() {
                    _resizeLock = v;
                    if (v) _resizeFieldEdited(widthEdited: true);
                  }),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: AccentButton(
                _l.gifEditorApply,
                key: const Key('gif-resize-apply'),
                onTap: () {
                  final w = int.tryParse(_resizeW.text);
                  final h = int.tryParse(_resizeH.text);
                  setState(_closePanels);
                  if (w != null && h != null && w > 0 && h > 0) {
                    unawaited(_c.resizeDoc(w, h));
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Delay operations panel (set / adjust / scale + value + apply).
  Widget _delayPanel(GlimprTokens t) {
    final suffix = _delayMode == _DelayMode.scale ? '%' : 'ms';
    return Positioned(
      left: 12,
      bottom: 86 + 40 + 8,
      child: Container(
        key: const Key('gif-delay-panel'),
        width: 332,
        padding: const EdgeInsets.fromLTRB(16, 13, 16, 16),
        decoration: _panelDecoration(t),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_l.gifEditorDelay,
                style: GlimprType.sansStyle(11.5, 600, t.fg3,
                    letterSpacing: 0.2)),
            const SizedBox(height: 10),
            Segmented<_DelayMode>(
              value: _delayMode,
              onChanged: (m) => setState(() => _delayMode = m),
              options: [
                (_DelayMode.set, _l.gifEditorDelaySet),
                (_DelayMode.adjust, _l.gifEditorDelayAdjust),
                (_DelayMode.scale, _l.gifEditorDelayScale),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                SizedBox(
                  width: 84,
                  child: TextField(
                    key: const Key('gif-delay-field'),
                    controller: _delayField,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      // Adjust accepts a leading minus; the others digits.
                      FilteringTextInputFormatter.allow(
                          _delayMode == _DelayMode.adjust
                              ? RegExp(r'^-?[0-9]*$')
                              : RegExp(r'^[0-9]*$')),
                      LengthLimitingTextInputFormatter(6),
                    ],
                    textAlign: TextAlign.center,
                    style: GlimprType.sansStyle(12.5, 600, t.fg1),
                    decoration: _fieldDecoration(t),
                  ),
                ),
                const SizedBox(width: 7),
                Text(suffix, style: GlimprType.sansStyle(12, 500, t.fg3)),
                const Spacer(),
                AccentButton(
                  _l.gifEditorApply,
                  key: const Key('gif-delay-apply'),
                  onTap: _applyDelay,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _applyDelay() {
    final n = int.tryParse(_delayField.text);
    if (n == null) return;
    switch (_delayMode) {
      case _DelayMode.set:
        _c.overrideDelay(n);
      case _DelayMode.adjust:
        _c.shiftDelay(n);
      case _DelayMode.scale:
        if (n > 0) _c.scaleDelay(n);
    }
    setState(_closePanels);
  }

  /// Reduce-frames panel (keep the first of every N).
  Widget _reducePanel(GlimprTokens t) {
    return Positioned(
      left: 12,
      bottom: 86 + 40 + 8,
      child: Container(
        key: const Key('gif-reduce-panel'),
        width: 332,
        padding: const EdgeInsets.fromLTRB(16, 13, 16, 16),
        decoration: _panelDecoration(t),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_l.gifEditorReduceKeepFirst,
                style: GlimprType.sansStyle(11.5, 600, t.fg3,
                    letterSpacing: 0.2)),
            const SizedBox(height: 10),
            Row(
              children: [
                Segmented<int>(
                  value: _reduceN,
                  onChanged: (n) => setState(() => _reduceN = n),
                  options: const [(2, '2'), (3, '3'), (4, '4'), (5, '5')],
                ),
                const Spacer(),
                AccentButton(
                  _l.gifEditorApply,
                  key: const Key('gif-reduce-apply'),
                  onTap: () {
                    _c.reduceFrames(_reduceN);
                    setState(_closePanels);
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  BoxDecoration _panelDecoration(GlimprTokens t) => BoxDecoration(
        color: t.hudBg,
        borderRadius: BorderRadius.circular(GlimprTokens.radiusBar),
        border: Border.all(color: t.hudBorder),
        boxShadow: [
          BoxShadow(
            color:
                t.isDark ? const Color(0x66000000) : const Color(0x2E0F172A),
            blurRadius: 16,
          ),
        ],
      );

  InputDecoration _fieldDecoration(GlimprTokens t) => InputDecoration(
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(7),
          borderSide: BorderSide(color: t.cardBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(7),
          borderSide: const BorderSide(color: GlimprTokens.accent),
        ),
      );

  Widget _controlsRow(GlimprTokens t, GifDocument doc) {
    final seconds = doc.totalDuration.inMilliseconds / 1000;
    final f = doc.frames.first;
    final loop = doc.loopCount == 0 ? '∞' : '×${doc.loopCount}';
    final stats = '${_l.gifEditorStatsFrames(doc.frameCount)}'
        ' · ${seconds.toStringAsFixed(1)}s'
        ' · ${f.width}×${f.height}'
        ' · $loop';
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: t.divider)),
      ),
      child: Row(
        children: [
          Tooltip(
            message: _c.playing ? _l.gifEditorPause : _l.gifEditorPlay,
            waitDuration: const Duration(milliseconds: 500),
            child: GestureDetector(
              key: const Key('gif-play-toggle'),
              onTap: _c.togglePlay,
              child: Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: t.cardBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: t.cardBorder),
                ),
                child: Icon(
                  _c.playing
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  size: 19,
                  color: t.fg1,
                ),
              ),
            ),
          ),
          const Spacer(),
          Text(stats, style: GlimprType.sansStyle(12, 500, t.fg3)),
          const SizedBox(width: 14),
          Tooltip(
            message: _l.gifEditorExportOptions,
            waitDuration: const Duration(milliseconds: 500),
            child: GestureDetector(
              key: const Key('gif-export-options'),
              onTap: () => setState(() {
                final open = _optionsOpen;
                _closePanels();
                _optionsOpen = !open;
              }),
              child: Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: t.cardBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color:
                          _optionsOpen ? GlimprTokens.accent : t.cardBorder),
                ),
                child: Icon(Icons.tune_rounded,
                    size: 17, color: _optionsOpen ? t.fg1 : t.fg2),
              ),
            ),
          ),
          const SizedBox(width: 8),
          AccentButton(
            _exporting
                ? '${(_exportProgress * 100).round()}%'
                : _l.gifEditorExportButton,
            icon: Icons.save_alt_rounded,
            onTap: () {
              if (!_exporting) unawaited(_export());
            },
          ),
        ],
      ),
    );
  }

  /// The export options popover: anchored above the controls row's right
  /// edge, dismissed by the outside-tap barrier. Same glass surface as the
  /// toast pill; controls reuse the app-wide idioms (Segmented, GlassToggle).
  Widget _optionsPopover(GlimprTokens t) {
    Widget row(String label, Widget control) => Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Row(
            children: [
              Expanded(
                child: Text(label,
                    style: GlimprType.sansStyle(12.5, 500, t.fg2)),
              ),
              control,
            ],
          ),
        );

    // Segmented controls are too wide to share a line with their label in
    // both languages; those sections stack label over control instead.
    Widget section(String label, Widget control) => Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: GlimprType.sansStyle(12.5, 500, t.fg2)),
              const SizedBox(height: 7),
              control,
            ],
          ),
        );

    return Positioned(
      right: 12,
      bottom: 86 + 40 + 44 + 8, // clear filmstrip + ops row + controls row
      child: Container(
        key: const Key('gif-options-popover'),
        width: 332,
        padding: const EdgeInsets.fromLTRB(16, 13, 16, 16),
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_l.gifEditorExportOptions,
                style: GlimprType.sansStyle(11.5, 600, t.fg3,
                    letterSpacing: 0.2)),
            section(
              _l.gifEditorPalette,
              Segmented<PaletteStrategy>(
                value: _optStrategy,
                onChanged: (v) => setState(() => _optStrategy = v),
                options: [
                  (PaletteStrategy.global, _l.gifEditorPaletteGlobal),
                  (PaletteStrategy.perFrame, _l.gifEditorPalettePerFrame),
                ],
              ),
            ),
            row(
              _l.gifEditorDither,
              GlassToggle(
                key: const Key('gif-opt-dither'),
                value: _optDither,
                onChanged: (v) => setState(() => _optDither = v),
              ),
            ),
            row(
              _l.gifEditorOptimize,
              GlassToggle(
                key: const Key('gif-opt-optimize'),
                value: _optOptimize,
                onChanged: (v) => setState(() => _optOptimize = v),
              ),
            ),
            section(
              _l.gifEditorLoop,
              Row(
                children: [
                  Segmented<bool>(
                    value: _optLoopForever,
                    onChanged: (v) => setState(() => _optLoopForever = v),
                    options: [
                      (true, _l.gifEditorLoopForever),
                      (false, _l.gifEditorLoopCount),
                    ],
                  ),
                  if (!_optLoopForever) ...[
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 52,
                      child: TextField(
                        key: const Key('gif-opt-loop-count-field'),
                        controller: _loopField,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(5),
                        ],
                        textAlign: TextAlign.center,
                        style: GlimprType.sansStyle(12.5, 600, t.fg1),
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 7),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(7),
                            borderSide: BorderSide(color: t.cardBorder),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(7),
                            borderSide:
                                const BorderSide(color: GlimprTokens.accent),
                          ),
                        ),
                        onChanged: (v) {
                          final n = int.tryParse(v);
                          if (n != null && n > 0) {
                            setState(() => _optLoopCount = n);
                          }
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _filmstrip(GlimprTokens t, GifDocument doc, FrameStore store) {
    return Container(
      height: 86,
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: t.divider)),
      ),
      // A plain vertical wheel scrolls the strip too (owner request): the
      // horizontal list only handles horizontal deltas natively (shift+wheel
      // or trackpad), so translate the vertical component ourselves.
      child: Listener(
        onPointerSignal: (e) {
          if (e is! PointerScrollEvent) return;
          final dy = e.scrollDelta.dy;
          if (dy == 0 || !_strip.hasClients) return;
          final pos = _strip.position;
          _strip.jumpTo(
              (pos.pixels + dy).clamp(0.0, pos.maxScrollExtent));
        },
        child: ListView.builder(
        controller: _strip,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        itemCount: doc.frameCount,
        itemBuilder: (ctx, i) {
          final f = doc.frames[i];
          final isCurrent = i == _c.current;
          final isSelected = _c.selection.contains(i);
          return GestureDetector(
            key: Key('gif-frame-$i'),
            // Plain click selects AND seeks; shift extends a range from the
            // anchor; cmd (mac) / ctrl (win) toggles membership. Modified
            // clicks only shape the selection, the playhead stays put.
            onTap: () {
              final keys = HardwareKeyboard.instance.logicalKeysPressed;
              final shift =
                  keys.contains(LogicalKeyboardKey.shiftLeft) ||
                      keys.contains(LogicalKeyboardKey.shiftRight);
              final mod = platformIsWindows
                  ? (keys.contains(LogicalKeyboardKey.controlLeft) ||
                      keys.contains(LogicalKeyboardKey.controlRight))
                  : (keys.contains(LogicalKeyboardKey.metaLeft) ||
                      keys.contains(LogicalKeyboardKey.metaRight));
              if (shift) {
                _c.select(i, range: true);
              } else if (mod) {
                _c.select(i, toggle: true);
              } else {
                _c.select(i);
                _c.seek(i);
              }
            },
            child: Container(
              width: 84,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                // Accent border marks the CURRENT frame; selected members
                // get an accent veil below.
                border: Border.all(
                  color: isCurrent || isSelected
                      ? GlimprTokens.accent
                      : t.cardBorder,
                  width: isCurrent ? 2 : 1,
                ),
              ),
              child: Column(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(7)),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          _FramePreview(store: store, frame: f),
                          if (isSelected)
                            Container(
                                color:
                                    GlimprTokens.accent.withValues(alpha: 0.16)),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Text(
                      '${i + 1} · ${f.delayMs} ms',
                      style: GlimprType.sansStyle(9.5, 500,
                          isCurrent || isSelected ? t.fg1 : t.fg4),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
        ),
      ),
    );
  }

  Widget _toastLayer(GlimprTokens t) {
    return Positioned(
      top: 32 + 12,
      left: 24,
      right: 24,
      child: IgnorePointer(
        child: AnimatedSlide(
          offset: _toastVisible ? Offset.zero : const Offset(0, -0.4),
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          child: AnimatedOpacity(
            opacity: _toastVisible ? 1 : 0,
            duration: const Duration(milliseconds: 220),
            child: Center(
              child: _toastMsg == null
                  ? const SizedBox.shrink()
                  : Container(
                      constraints: const BoxConstraints(maxWidth: 560),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 9),
                      decoration: BoxDecoration(
                        color: t.hudBg,
                        borderRadius:
                            BorderRadius.circular(GlimprTokens.radiusBar),
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
                      child: Text(
                        _toastMsg!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: GlimprType.sansStyle(13.5, 600, t.fg1),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Which timeline panel is open above the ops row.
enum _TimelinePanel { none, delay, reduce, resize }

/// Delay-popover operation modes.
enum _DelayMode { set, adjust, scale }

/// Small icon button for the timeline ops row: hover highlight, disabled
/// dimming, optional active (accent) state for popover triggers.
class _OpButton extends StatefulWidget {
  const _OpButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.enabled = true,
    this.active = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool enabled;
  final bool active;

  @override
  State<_OpButton> createState() => _OpButtonState();
}

class _OpButtonState extends State<_OpButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = GlimprTheme.of(context);
    final color = !widget.enabled
        ? t.fg4
        : widget.active || _hover
            ? t.fg1
            : t.fg2;
    return MouseRegion(
      cursor: widget.enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.enabled ? widget.onTap : null,
        child: Tooltip(
          message: widget.tooltip,
          waitDuration: const Duration(milliseconds: 500),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 28,
            height: 28,
            margin: const EdgeInsets.symmetric(horizontal: 1),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: widget.active
                  ? GlimprTokens.accent.withValues(alpha: 0.18)
                  : _hover && widget.enabled
                      ? t.navHoverBg
                      : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
              border: widget.active
                  ? Border.all(color: GlimprTokens.accent)
                  : null,
            ),
            child: Icon(widget.icon, size: 16, color: color),
          ),
        ),
      ),
    );
  }
}

/// Crop mode surface over the preview: draw a rectangle, move it, resize it
/// by its 8 handles, and confirm or cancel. The rect is kept in IMAGE pixel
/// coordinates; this widget maps pointer positions through the same
/// contain-fit math the preview paints with.
class _CropOverlay extends StatefulWidget {
  const _CropOverlay({
    required this.store,
    required this.frame,
    required this.rect,
    required this.onRectChanged,
    required this.onApply,
    required this.onCancel,
  });

  final FrameStore store;
  final GifFrame frame;
  final Rect? rect;
  final ValueChanged<Rect?> onRectChanged;
  final VoidCallback onApply;
  final VoidCallback onCancel;

  @override
  State<_CropOverlay> createState() => _CropOverlayState();
}

/// What a drag that started on the crop rect is doing.
enum _CropDrag { draw, move, resize }

class _CropOverlayState extends State<_CropOverlay> {
  _CropDrag _drag = _CropDrag.draw;
  Offset _anchor = Offset.zero; // image coords: draw origin / move grab
  Rect _grabRect = Rect.zero; // rect at move-start
  // Which edges the active resize handle owns.
  bool _hLeft = false, _hRight = false, _hTop = false, _hBottom = false;

  @override
  Widget build(BuildContext context) {
    final t = GlimprTheme.of(context);
    final l = AppLocalizations.of(context);
    final iw = widget.frame.width.toDouble();
    final ih = widget.frame.height.toDouble();
    return LayoutBuilder(builder: (context, box) {
      final scale =
          (box.maxWidth / iw < box.maxHeight / ih)
              ? box.maxWidth / iw
              : box.maxHeight / ih;
      final dispW = iw * scale;
      final dispH = ih * scale;
      final off = Offset(
          (box.maxWidth - dispW) / 2, (box.maxHeight - dispH) / 2);

      Offset toImage(Offset local) => Offset(
            ((local.dx - off.dx) / scale).clamp(0, iw),
            ((local.dy - off.dy) / scale).clamp(0, ih),
          );
      Rect toView(Rect img) => Rect.fromLTRB(
            off.dx + img.left * scale,
            off.dy + img.top * scale,
            off.dx + img.right * scale,
            off.dy + img.bottom * scale,
          );

      final viewRect = widget.rect == null ? null : toView(widget.rect!);

      void panStart(DragStartDetails d) {
        final p = d.localPosition;
        if (viewRect != null) {
          const grab = 14.0;
          bool near(double a, double b) => (a - b).abs() <= grab;
          final onLeft = near(p.dx, viewRect.left);
          final onRight = near(p.dx, viewRect.right);
          final onTop = near(p.dy, viewRect.top);
          final onBottom = near(p.dy, viewRect.bottom);
          final inX = p.dx >= viewRect.left - grab &&
              p.dx <= viewRect.right + grab;
          final inY = p.dy >= viewRect.top - grab &&
              p.dy <= viewRect.bottom + grab;
          if ((onLeft || onRight) && inY || (onTop || onBottom) && inX) {
            _drag = _CropDrag.resize;
            _hLeft = onLeft && inY;
            _hRight = onRight && inY && !_hLeft;
            _hTop = onTop && inX;
            _hBottom = onBottom && inX && !_hTop;
            return;
          }
          if (viewRect.contains(p)) {
            _drag = _CropDrag.move;
            _anchor = toImage(p);
            _grabRect = widget.rect!;
            return;
          }
        }
        _drag = _CropDrag.draw;
        _anchor = toImage(p);
        widget.onRectChanged(Rect.fromPoints(_anchor, _anchor));
      }

      void panUpdate(DragUpdateDetails d) {
        final img = toImage(d.localPosition);
        switch (_drag) {
          case _CropDrag.draw:
            widget.onRectChanged(Rect.fromPoints(_anchor, img));
          case _CropDrag.move:
            final delta = img - _anchor;
            final dx = delta.dx
                .clamp(-_grabRect.left, iw - _grabRect.right);
            final dy =
                delta.dy.clamp(-_grabRect.top, ih - _grabRect.bottom);
            widget.onRectChanged(_grabRect.shift(Offset(dx, dy)));
          case _CropDrag.resize:
            final r = widget.rect!;
            widget.onRectChanged(Rect.fromLTRB(
              _hLeft ? img.dx : r.left,
              _hTop ? img.dy : r.top,
              _hRight ? img.dx : r.right,
              _hBottom ? img.dy : r.bottom,
            ));
        }
      }

      void panEnd(DragEndDetails d) {
        final r = widget.rect;
        if (r == null) return;
        // Normalize (a resize may cross itself) and drop empty rects.
        final norm = Rect.fromLTRB(
          r.left < r.right ? r.left : r.right,
          r.top < r.bottom ? r.top : r.bottom,
          r.left < r.right ? r.right : r.left,
          r.top < r.bottom ? r.bottom : r.top,
        );
        widget.onRectChanged(
            norm.width < 1 || norm.height < 1 ? null : norm);
      }

      final intW = widget.rect == null
          ? 0
          : widget.rect!.right.round() - widget.rect!.left.round();
      final intH = widget.rect == null
          ? 0
          : widget.rect!.bottom.round() - widget.rect!.top.round();

      return Stack(
        children: [
          Positioned.fill(
              child: _FramePreview(store: widget.store, frame: widget.frame)),
          Positioned.fill(
            child: GestureDetector(
              key: const Key('gif-crop-overlay'),
              behavior: HitTestBehavior.opaque,
              onPanStart: panStart,
              onPanUpdate: panUpdate,
              onPanEnd: panEnd,
              child: CustomPaint(
                painter: _CropPainter(
                  imageRect: Rect.fromLTWH(off.dx, off.dy, dispW, dispH),
                  rect: viewRect,
                  dark: t.isDark,
                ),
              ),
            ),
          ),
          // Hint before a rect exists; dims + confirm bar once drawn.
          if (widget.rect == null)
            Positioned(
              top: 10,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: t.hudBg,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: t.hudBorder),
                    ),
                    child: Text(l.gifEditorCropHint,
                        style: GlimprType.sansStyle(12, 500, t.fg2)),
                  ),
                ),
              ),
            )
          else
            Positioned(
              bottom: 10,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: t.hudBg,
                    borderRadius:
                        BorderRadius.circular(GlimprTokens.radiusBar),
                    border: Border.all(color: t.hudBorder),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('$intW×$intH',
                          style: GlimprType.sansStyle(12.5, 600, t.fg2)),
                      const SizedBox(width: 12),
                      GestureDetector(
                        key: const Key('gif-crop-cancel'),
                        onTap: widget.onCancel,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 4),
                          child: Text(l.gifEditorCancel,
                              style:
                                  GlimprType.sansStyle(12.5, 600, t.fg3)),
                        ),
                      ),
                      const SizedBox(width: 6),
                      AccentButton(
                        l.gifEditorApply,
                        key: const Key('gif-crop-apply'),
                        onTap: widget.onApply,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      );
    });
  }
}

/// Dim outside the crop rect, stroke it, and draw its 8 handles.
class _CropPainter extends CustomPainter {
  const _CropPainter(
      {required this.imageRect, required this.rect, required this.dark});

  final Rect imageRect;
  final Rect? rect;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final dim = Paint()
      ..color = dark ? const Color(0x8A000000) : const Color(0x66000000);
    final r = rect;
    if (r == null) {
      canvas.drawRect(imageRect, dim);
      return;
    }
    final clipped = r.intersect(imageRect);
    canvas.drawRect(
        Rect.fromLTRB(
            imageRect.left, imageRect.top, imageRect.right, clipped.top),
        dim);
    canvas.drawRect(
        Rect.fromLTRB(imageRect.left, clipped.bottom, imageRect.right,
            imageRect.bottom),
        dim);
    canvas.drawRect(
        Rect.fromLTRB(
            imageRect.left, clipped.top, clipped.left, clipped.bottom),
        dim);
    canvas.drawRect(
        Rect.fromLTRB(
            clipped.right, clipped.top, imageRect.right, clipped.bottom),
        dim);

    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = GlimprTokens.accent;
    canvas.drawRect(clipped, stroke);

    final handle = Paint()..color = GlimprTokens.accent;
    const s = 7.0;
    for (final c in [
      clipped.topLeft,
      Offset(clipped.center.dx, clipped.top),
      clipped.topRight,
      Offset(clipped.left, clipped.center.dy),
      Offset(clipped.right, clipped.center.dy),
      clipped.bottomLeft,
      Offset(clipped.center.dx, clipped.bottom),
      clipped.bottomRight,
    ]) {
      canvas.drawRect(
          Rect.fromCenter(center: c, width: s, height: s), handle);
    }
  }

  @override
  bool shouldRepaint(_CropPainter old) =>
      old.rect != rect || old.imageRect != imageRect || old.dark != dark;
}

/// Paints one stored frame, keeping the PREVIOUS image on screen while the
/// next one decodes (a FutureBuilder would flash empty on every seek).
class _FramePreview extends StatefulWidget {
  const _FramePreview({required this.store, required this.frame});

  final FrameStore store;
  final GifFrame frame;

  @override
  State<_FramePreview> createState() => _FramePreviewState();
}

class _FramePreviewState extends State<_FramePreview> {
  ui.Image? _image;
  FrameKey? _shownKey;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_FramePreview old) {
    super.didUpdateWidget(old);
    if (old.frame.key != widget.frame.key) _load();
  }

  Future<void> _load() async {
    final f = widget.frame;
    final ui.Image img;
    try {
      img = await widget.store.image(f.key, f.width, f.height);
    } catch (_) {
      // The store can be disposed mid-load (home / document swap); the
      // widget unmounts moments later, so just keep the stale image.
      return;
    }
    if (!mounted || widget.frame.key != f.key) return;
    setState(() {
      _image = img;
      _shownKey = f.key;
    });
  }

  @override
  Widget build(BuildContext context) {
    // Keep painting the stale image until the new one lands; the key check
    // in _load prevents an out-of-order overwrite.
    if (_image == null) return const SizedBox.expand();
    return RawImage(
      image: _image,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      // Repaint hint only; RawImage compares images by identity anyway.
      key: ValueKey(_shownKey),
    );
  }
}

/// Title-bar back-to-landing affordance (macOS only; the Image Editor idiom).
class _TitleBarHome extends StatefulWidget {
  const _TitleBarHome({super.key, required this.onTap});
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

/// Floating glass Home over the canvas (Windows; no Flutter title bar there).
class _FloatingHomeButton extends StatefulWidget {
  const _FloatingHomeButton({super.key, required this.onTap});
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
                Icon(Icons.home_outlined, size: 15, color: color),
                const SizedBox(width: 6),
                Text(l.editorGalleryHome,
                    style: GlimprType.sansStyle(12, 600, color)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
