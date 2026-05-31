import 'package:flutter/material.dart';
import 'capture/capture_bridge.dart';

void main() => runApp(const GlimprDebugApp());

class GlimprDebugApp extends StatefulWidget {
  const GlimprDebugApp({super.key});
  @override
  State<GlimprDebugApp> createState() => _GlimprDebugAppState();
}

class _GlimprDebugAppState extends State<GlimprDebugApp> {
  final _bridge = CaptureBridge();
  String _status = 'Press Capture to trigger the overlay.';

  @override
  void initState() {
    super.initState();
    _bridge.registerOverlayHandlers(
      onCaptureReady: (_) {},
      onCaptureFailed: (reason, msg) => setState(() => _status = '$reason: $msg'),
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Glimpr',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          appBar: AppBar(title: const Text('Glimpr — debug control')),
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FilledButton(
                  onPressed: () => _bridge.beginCapture(),
                  child: const Text('Capture'),
                ),
                const SizedBox(height: 12),
                Text(_status),
              ],
            ),
          ),
        ),
      );
}
