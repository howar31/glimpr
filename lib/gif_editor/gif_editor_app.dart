import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n/gen/app_localizations.dart';
import '../platform_gate.dart';
import '../settings/app_locale.dart';
import '../theme/glimpr_controls.dart';
import '../theme/glimpr_theme.dart';
import 'frame_store.dart';
import 'gif_document.dart';
import 'gif_import.dart';

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
  const GifEditorApp({super.key});

  @override
  State<GifEditorApp> createState() => _GifEditorAppState();
}

class _GifEditorAppState extends State<GifEditorApp>
    with WidgetsBindingObserver {
  // Resolved from a context inside the MaterialApp's Localizations scope
  // (same field pattern as the Image Editor).
  late AppLocalizations _l;

  static const _channel = MethodChannel('glimpr/gifEditor');

  FrameStore? _store;
  GifDocument? _doc;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_store?.dispose());
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() => setState(() {});

  Future<void> _openPanel() async {
    if (_opening) return;
    final path = await _channel.invokeMethod<String>('openPanel');
    if (path == null || path.isEmpty) return;
    await _load(path);
  }

  Future<void> _load(String path) async {
    setState(() => _opening = true);
    try {
      final bytes = await File(path).readAsBytes();
      // A fresh session directory per opened GIF; the previous document's
      // store (if any) is disposed after the swap so undo keys never dangle.
      final dir =
          await Directory.systemTemp.createTemp('glimpr_gif_editor');
      final store = FrameStore(dir);
      final doc = await importGif(Uint8List.fromList(bytes), store);
      final old = _store;
      setState(() {
        _store = store;
        _doc = doc;
        _opening = false;
      });
      unawaited(old?.dispose());
    } catch (_) {
      setState(() => _opening = false);
      _toast(_l.gifEditorOpenFailed);
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
                          child: _doc == null
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
              _opening
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

  /// Loaded state. S1-T5 fills this with the preview canvas, the filmstrip
  /// timeline, playback and stats; this placeholder only proves the state
  /// swap end to end.
  Widget _editor(GlimprTokens t) {
    return Container(
      key: const Key('gif-editor-canvas'),
      alignment: Alignment.center,
      child: Text(
        _l.gifEditorStatsFrames(_doc!.frameCount),
        style: GlimprType.sansStyle(13, 500, t.fg2),
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
