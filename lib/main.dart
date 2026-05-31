import 'dart:ui' show Rect;
import 'package:flutter/material.dart';
import 'capture/capture_bridge.dart';
import 'capture/captured_display.dart';
import 'overlay/overlay_canvas.dart';
import 'overlay/export.dart';
import 'debug_log.dart';

void main() {
  glog('main() running');
  runApp(const GlimprApp());
}

/// Single-window milestone: the overlay is rendered inside THIS (the proven-
/// rendering) window. Idle shows the debug control; on capture the same window
/// shows the freeze overlay (frozen image + marquee). Fullscreen/borderless
/// chrome and per-display windows are follow-ups (separate per-display engines
/// did not render on this macOS/Flutter combo).
class GlimprApp extends StatefulWidget {
  const GlimprApp({super.key});
  @override
  State<GlimprApp> createState() => _GlimprAppState();
}

class _GlimprAppState extends State<GlimprApp> {
  final _bridge = CaptureBridge();
  String _status = 'Press Capture.';
  CapturedDisplay? _overlay;

  @override
  void initState() {
    super.initState();
    _bridge.registerOverlayHandlers(
      onCaptureReady: (d) {
        glog('onCaptureReady -> show overlay in window, display=${d.displayId}');
        setState(() => _overlay = d);
      },
      onCaptureFailed: (reason, msg) {
        glog('onCaptureFailed: $reason $msg');
        setState(() {
          _overlay = null;
          _status = '$reason: $msg';
        });
      },
    );
  }

  void _dismiss() {
    setState(() => _overlay = null);
    _bridge.dismissOverlay();
  }

  @override
  Widget build(BuildContext context) {
    final d = _overlay;
    return MaterialApp(
      title: 'Glimpr',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true),
      home: d == null
          ? Scaffold(
              appBar: AppBar(title: const Text('Glimpr — debug control')),
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FilledButton(
                      onPressed: () {
                        glog('Capture clicked');
                        _bridge.beginCapture();
                      },
                      child: const Text('Capture'),
                    ),
                    const SizedBox(height: 12),
                    Text(_status),
                  ],
                ),
              ),
            )
          : OverlayCanvas(
              display: d,
              onCancel: _dismiss,
              onCommit: (Rect r) async {
                await exportSelection(display: d, selection: r);
                _dismiss();
              },
            ),
    );
  }
}
