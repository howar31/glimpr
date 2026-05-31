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
        // Decode the frozen image into the cache BEFORE showing, so the first
        // built frame paints it synchronously (no flash of an unpainted frame).
        await precacheImage(MemoryImage(d.pngBytes), context);
        if (!mounted) return;
        setState(() => _display = d);
        // After the frame with the painted image, ask native to reveal the window.
        WidgetsBinding.instance.addPostFrameCallback((_) => _bridge.overlayReady());
      },
      onCaptureFailed: (_, msg) => setState(() => _display = null),
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
          ? const SizedBox.expand()
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
