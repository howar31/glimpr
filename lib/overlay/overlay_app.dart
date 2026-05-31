import 'package:flutter/material.dart';
import '../capture/capture_bridge.dart';
import '../capture/captured_display.dart';
import '../output/deliver.dart';
import 'export.dart';
import 'overlay_canvas.dart';

class OverlayApp extends StatefulWidget {
  const OverlayApp({super.key});
  @override
  State<OverlayApp> createState() => _OverlayAppState();
}

class _OverlayAppState extends State<OverlayApp> {
  final _bridge = CaptureBridge();
  CapturedDisplay? _display;
  String? _toast; // shown briefly only when a delivery leg failed

  @override
  void initState() {
    super.initState();
    _bridge.registerOverlayHandlers(
      onCaptureReady: (d) async {
        // Decode the frozen image before we reveal the window. The engine is
        // already warm (its window is on-screen at alpha 0), so this resolves;
        // still BOUNDED so a decode hiccup can't stall the reveal.
        try {
          await precacheImage(MemoryImage(d.pngBytes), context)
              .timeout(const Duration(milliseconds: 300));
        } catch (_) {
          // Bounded best-effort decode; reveal anyway on failure/timeout.
        }
        if (!mounted) return;
        setState(() {
          _toast = null;
          _display = d;
        });
        // The frozen frame is now built (painted into the alpha-0 window). Tell
        // native to reveal this display's window (alpha 1 + makeKey) so the
        // already-rasterized frame appears with no blank flash.
        _bridge.overlayReady();
      },
      onCaptureFailed: (reason, msg) {
        if (mounted) setState(() => _display = null);
      },
    );
  }

  void _dismiss() {
    setState(() {
      _display = null;
      _toast = null;
    });
    _bridge.dismissOverlay();
  }

  Future<void> _onCommit(Rect selection) async {
    final d = _display;
    if (d == null) {
      _dismiss();
      return;
    }
    final result = await exportSelection(display: d, selection: selection);
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
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(scaffoldBackgroundColor: Colors.transparent),
      home: d == null
          // Idle: fully transparent so the warm, on-screen overlay window shows
          // nothing until a capture sets the frozen frame.
          ? const SizedBox.shrink()
          : Stack(
              fit: StackFit.expand,
              children: [
                OverlayCanvas(
                  display: d,
                  onCancel: _dismiss,
                  onCommit: _onCommit,
                ),
                if (_toast != null)
                  Positioned(
                    bottom: 48,
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
