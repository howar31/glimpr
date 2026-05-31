import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'capture/capture_bridge.dart';
import 'overlay/overlay_app.dart';
import 'shell/hotkey.dart';

/// Every engine runs this same main(). The native side answers `glimpr/role`
/// with 'overlay' for the per-display overlay engines and 'debug' for the main
/// control window, so we mount the right widget tree per engine.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final role = await _getRole();
  if (role == 'overlay') {
    runApp(const OverlayApp());
    return;
  }
  // Control engine only: register the global capture hotkey (⌘⌥1). The
  // per-display overlay engines must NOT also register it (one system hotkey).
  try {
    await CaptureHotkey.register(() => CaptureBridge().beginCapture());
  } catch (_) {
    // A hotkey failure must not block the app; the Capture button still works.
  }
  runApp(const GlimprApp());
}

/// Resolves this engine's role. The native handler is registered synchronously
/// at controller creation, but retry a few times in case Dart wins the race;
/// default to the debug control if the channel never answers.
Future<String> _getRole() async {
  const channel = MethodChannel('glimpr/role');
  for (var attempt = 0; attempt < 10; attempt++) {
    try {
      final role = await channel.invokeMethod<String>('getRole');
      if (role != null) return role;
    } on MissingPluginException {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    } catch (_) {
      break; // unexpected channel error — fall back to the debug role
    }
  }
  return 'debug';
}

/// Debug control window: triggers the multi-display overlay and surfaces capture
/// failures. The freeze overlay itself renders in the per-display OverlayApp
/// windows, not here.
class GlimprApp extends StatefulWidget {
  const GlimprApp({super.key});
  @override
  State<GlimprApp> createState() => _GlimprAppState();
}

class _GlimprAppState extends State<GlimprApp> {
  final _bridge = CaptureBridge();
  String _status = 'Press Capture.';

  @override
  void initState() {
    super.initState();
    _bridge.registerOverlayHandlers(
      // The overlay renders in its own per-display window, not here; this engine
      // only needs to surface capture failures.
      onCaptureReady: (_) {},
      onCaptureFailed: (reason, msg) =>
          setState(() => _status = '$reason: $msg'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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
}
