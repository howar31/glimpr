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
      onCaptureReady: (d) {
        setState(() => _display = d);
        // After this frame rasterizes, tell native to show the window.
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
