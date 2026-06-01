import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../capture/capture_bridge.dart';
import '../capture/captured_display.dart';
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
  String? _toast; // shown briefly only when a delivery leg failed

  @override
  void initState() {
    super.initState();
    _bridge.registerOverlayHandlers(
      onCaptureReady: (d) async {
        // Warm-decode the image both for the on-screen Image.memory and for the
        // export ui.Image. The engine is already warm (window on-screen at
        // alpha 0), so these resolve; bounded so a hiccup can't stall the reveal.
        try {
          await precacheImage(MemoryImage(d.pngBytes), context)
              .timeout(const Duration(milliseconds: 300));
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
        _editor?.dispose();
        _frozen?.dispose();
        setState(() {
          _toast = null;
          _frozen = frozen;
          _editor = EditorController();
          _display = d;
        });
        // Frozen frame is built; reveal this display's window (no blank flash).
        _bridge.overlayReady();
      },
      onCaptureFailed: (reason, msg) {
        if (mounted) _resetState();
      },
    );
  }

  void _resetState() {
    _editor?.dispose();
    _frozen?.dispose();
    setState(() {
      _display = null;
      _toast = null;
      _editor = null;
      _frozen = null;
    });
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
          : Stack(
              fit: StackFit.expand,
              children: [
                EditorCanvas(
                  display: d,
                  controller: editor,
                  onExport: _onExport,
                  onCancel: _dismiss,
                ),
                if (_toast != null)
                  Positioned(
                    bottom: 80,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xE6B00020),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          _toast!,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 14),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
