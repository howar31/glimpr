import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../capture/capture_bridge.dart';
import '../capture/captured_display.dart';
import '../editor/draw_style.dart';
import '../editor/editor_controller.dart';
import '../output/deliver.dart';
import '../output/sounds.dart';
import '../settings/settings.dart';
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
  // Capture-time settings, prefetched per capture (in onCaptured) so the
  // shutter sound + delivery never await the store on the commit hot path.
  CaptureSettings _capture = CaptureSettings.defaults;
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
          codec.dispose(); // release the decoder's native memory immediately
        } catch (_) {
          // If decode fails the export will be skipped; the overlay still shows.
        }
        if (!mounted) return;
        _detachShared();
        _editor?.dispose();
        _frozen?.dispose();
        setState(() {
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
        // Prefetch settings off the hot path: the read completes during the
        // user's crop interaction, so _onExport reads _capture synchronously.
        Settings.instance.loadCapture().then((c) {
          // setState so a fresh capture's EditorCanvas picks up settings that
          // affect interaction (e.g. rightClickExits); shutter/delivery read
          // _capture directly at export time.
          if (mounted) setState(() => _capture = c);
        });
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
    // Snapshot the (immutable) inputs, then HIDE the overlay IMMEDIATELY so the
    // user isn't staring at the frozen frame while we composite / encode /
    // deliver. This export takes over the frozen image's lifecycle (disposes it
    // when done), so null _frozen first to keep _dismiss/_resetState from
    // disposing it out from under the background work. The shutter sound is the
    // last delivery leg, so it lands on completion.
    final cap = _capture; // snapshot prefetched at capture (off the hot path)
    if (cap.shutterSound) {
      playShutter(); // shutter at the instant of capture (fire-and-forget)
    }
    final drawables = editor.document.value.drawables;
    _frozen = null;
    _dismiss();
    try {
      final result = await exportAnnotated(
        display: d,
        frozenImage: frozen,
        drawables: drawables,
        selectionLogical: selectionLogical,
        cap: cap,
      );
      // Success = every ENABLED leg succeeded (a disabled leg is not a failure).
      // On success play the completion chime (if enabled); on a real failure the
      // overlay is already gone, so surface it via a native alert.
      final ok =
          (!cap.saveToFile || result.savedOk) &&
          (!cap.copyToClipboard || result.copiedToClipboard);
      if (ok) {
        if (cap.completionSound) playComplete();
      } else {
        _bridge.showError(_summary(result, cap));
      }
    } catch (e) {
      _bridge.showError('Capture failed: $e');
    } finally {
      frozen.dispose();
    }
  }

  String _summary(DeliveryResult r, CaptureSettings cap) {
    final saveFailed = cap.saveToFile && !r.savedOk;
    final clipFailed = cap.copyToClipboard && !r.copiedToClipboard;
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
                  rightClickExits: _capture.rightClickExits,
                ),
              ],
            ),
    );
  }
}
