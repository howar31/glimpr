import 'package:flutter/material.dart';
import '../capture/capture_bridge.dart';
import '../capture/captured_display.dart';
import 'export.dart';
import 'overlay_canvas.dart';
import '../debug_log.dart';

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
    glog('OverlayApp.initState: registering overlay handlers');
    _bridge.registerOverlayHandlers(
      onCaptureReady: (d) async {
        glog('onCaptureReady display=${d.displayId} ${d.width.toInt()}x${d.height.toInt()}');
        // Best-effort image warm, BOUNDED: a hidden engine may never resolve the
        // decode, so cap it so we can't stall here.
        try {
          await precacheImage(MemoryImage(d.pngBytes), context)
              .timeout(const Duration(milliseconds: 300));
        } catch (e) {
          glog('precacheImage skipped: $e');
        }
        if (!mounted) return;
        setState(() => _display = d);
        // The overlay engine has no on-screen view yet — it renders nothing
        // until native attaches the view controller to the window. So signal
        // ready immediately after the state is set; native then attaches the
        // view + reveals the window, which triggers the first render of the
        // (now set) frozen frame.
        glog('overlayReady() -> native, display=${d.displayId}');
        _bridge.overlayReady();
      },
      onCaptureFailed: (reason, msg) {
        glog('onCaptureFailed: $reason $msg');
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
          ? const ColoredBox(
              color: Color(0xFFFF0000),
              child: Center(
                child: Text('OVERLAY RENDERS',
                    style: TextStyle(color: Colors.white, fontSize: 48)),
              ),
            ) // TEMP render test: opaque red proves the overlay view paints.
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
