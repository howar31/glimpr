import 'package:flutter/material.dart';
import '../capture/capture_bridge.dart';
import '../capture/captured_display.dart';
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
        setState(() => _display = d);
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
    setState(() => _display = null);
    _bridge.dismissOverlay();
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
          : OverlayCanvas(
              display: d,
              onCancel: _dismiss,
              onCommit: (Rect r) async {
                final d = _display;
                if (d != null) {
                  await exportSelection(display: d, selection: r);
                }
                _dismiss();
              },
            ),
    );
  }
}
