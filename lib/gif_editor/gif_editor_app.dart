import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

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
    _toastTimer?.cancel();
    _toastClearTimer?.cancel();
    super.dispose();
  }

  void _onControllerChanged() => setState(() {});

  @override
  void didChangePlatformBrightness() => setState(() {});

  // Basename of the opened file; seeds the export save panel's suggestion.
  String _sourceName = 'animation';
  bool _exporting = false;
  double _exportProgress = 0;

  Future<void> _openPanel() async {
    if (_c.opening) return;
    final path = await _channel.invokeMethod<String>('openPanel');
    if (path == null || path.isEmpty) return;
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
    if (doc == null || store == null || _exporting) return;
    final out = await _channel.invokeMethod<String>(
        'savePanel', {'suggestedName': '$_sourceName-edited.gif'});
    if (out == null || out.isEmpty) return;
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
            const SingleActivator(LogicalKeyboardKey.space): () {
              if (_c.doc != null) _c.togglePlay();
            },
          },
          child: Scaffold(
            // Windows paints the opaque themed base (winBase rule); macOS
            // stays pure native vibrancy.
            backgroundColor:
                platformIsWindows ? tokens.winBase : Colors.transparent,
            body: Builder(
              builder: (ctx) {
                _l = AppLocalizations.of(ctx);
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
                    _toastLayer(tokens),
                  ],
                );
              },
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
                  child: _FramePreview(store: store, frame: frame),
                ),
              ),
            ],
          ),
        ),
        _controlsRow(t, doc),
        _filmstrip(t, doc, store),
      ],
    );
  }

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

  Widget _filmstrip(GlimprTokens t, GifDocument doc, FrameStore store) {
    return Container(
      height: 86,
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: t.divider)),
      ),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        itemCount: doc.frameCount,
        itemBuilder: (ctx, i) {
          final f = doc.frames[i];
          final selected = i == _c.current;
          return GestureDetector(
            key: Key('gif-frame-$i'),
            onTap: () => _c.seek(i),
            child: Container(
              width: 84,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                // Accent marks the CURRENT frame (accent = active/selected).
                border: Border.all(
                  color: selected ? GlimprTokens.accent : t.cardBorder,
                  width: selected ? 2 : 1,
                ),
              ),
              child: Column(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(7)),
                      child: _FramePreview(store: store, frame: f),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Text(
                      '${i + 1} · ${f.delayMs} ms',
                      style: GlimprType.sansStyle(
                          9.5, 500, selected ? t.fg1 : t.fg4),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
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
    final img = await widget.store.image(f.key, f.width, f.height);
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
