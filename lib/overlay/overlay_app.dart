import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../capture/capture_bridge.dart';
import '../capture/captured_display.dart';
import '../editor/draw_style.dart';
import '../editor/editor_controller.dart';
import '../output/deliver.dart';
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
  EditorController? _editor;
  // Last-used style per tool, persisted across captures (in-session).
  final Map<ToolKind, DrawStyle> _toolStyles = {};
  String? _toast; // shown briefly only when a delivery leg failed
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

  @override
  void initState() {
    super.initState();
    _bridge.registerOverlayHandlers(
      onCaptureReady: (d) async {
        // Warm-decode the image both for the on-screen Image.memory and for the
        // export ui.Image. The engine is already warm (window on-screen at
        // alpha 0), so these resolve; bounded so a hiccup can't stall the reveal.
        try {
          await precacheImage(
            MemoryImage(d.pngBytes),
            context,
          ).timeout(const Duration(milliseconds: 300));
        } catch (_) {
          // Bounded best-effort decode; reveal anyway on failure/timeout.
        }
        ui.Image? frozen;
        try {
          final codec = await ui.instantiateImageCodec(d.pngBytes);
          frozen = (await codec.getNextFrame()).image;
        } catch (_) {
          // If decode fails the export will be skipped; the overlay still shows.
        }
        if (!mounted) return;
        _detachShared();
        _editor?.dispose();
        _frozen?.dispose();
        setState(() {
          _toast = null;
          _frozen = frozen;
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
      },
      onCaptureFailed: (reason, msg) {
        if (mounted) _resetState();
      },
      onActiveDisplay: (activeId, cursor) {
        if (mounted) _activeSignal.value = (id: activeId, cursor: cursor);
      },
      onEditorState: _applyRemoteEditorState,
    );
  }

  void _resetState() {
    _detachShared();
    _editor?.dispose();
    _frozen?.dispose();
    setState(() {
      _display = null;
      _toast = null;
      _editor = null;
      _frozen = null;
    });
  }

  // ---- cross-display tool/style sync -------------------------------------

  void _attachShared(EditorController e) {
    e.tool.addListener(_broadcastEditorState);
    e.style.addListener(_broadcastEditorState);
  }

  void _detachShared() {
    _editor?.tool.removeListener(_broadcastEditorState);
    _editor?.style.removeListener(_broadcastEditorState);
  }

  /// Push the active tool + style to the other displays (skipped while applying
  /// a remote update, so the two engines don't ping-pong).
  void _broadcastEditorState() {
    if (_applyingRemote) return;
    final e = _editor;
    if (e == null) return;
    final s = e.style.value;
    _bridge.broadcastEditorState({
      'tool': e.tool.value.index,
      'color': s.color.toARGB32(),
      'strokeWidth': s.strokeWidth,
      'fontSize': s.fontSize,
    });
  }

  /// Mirror a tool/style change received from another display onto this editor.
  void _applyRemoteEditorState(Map<String, dynamic> state) {
    final e = _editor;
    if (e == null) return;
    _applyingRemote = true;
    final t = ToolKind.values[state['tool'] as int];
    final s = DrawStyle(
      color: Color(state['color'] as int),
      strokeWidth: (state['strokeWidth'] as num).toDouble(),
      fontSize: (state['fontSize'] as num).toDouble(),
    );
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

  Future<void> _onExport(Rect? selectionLogical) async {
    final d = _display;
    final frozen = _frozen;
    final editor = _editor;
    if (d == null || frozen == null || editor == null) {
      _dismiss();
      return;
    }
    final result = await exportAnnotated(
      display: d,
      frozenImage: frozen,
      drawables: editor.document.value.drawables,
      selectionLogical: selectionLogical,
    );
    // Save + clipboard are the legs that matter; a sound-only failure still
    // dismisses (the capture succeeded where it counts).
    final critical = !result.savedOk || !result.copiedToClipboard;
    if (!critical || !mounted) {
      _dismiss();
      return;
    }
    setState(() => _toast = _summary(result));
    Future.delayed(const Duration(milliseconds: 1600), () {
      if (mounted) _dismiss();
    });
  }

  String _summary(DeliveryResult r) {
    if (r.savedOk && !r.copiedToClipboard) return 'Saved — clipboard failed';
    if (!r.savedOk && r.copiedToClipboard) return 'Copied — file save failed';
    return 'Capture failed — not saved or copied';
  }

  @override
  Widget build(BuildContext context) {
    final d = _display;
    final frozen = _frozen;
    final editor = _editor;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
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
                  onCancel: _dismiss,
                  activeSignal: _activeSignal,
                ),
                if (_toast != null)
                  Positioned(
                    bottom: 80,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xE6B00020),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _toast!,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
