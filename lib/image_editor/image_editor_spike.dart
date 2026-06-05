import 'package:flutter/material.dart';

/// TEMPORARY render-loop spike (Phase 5 Plan 2a). Mounted when the engine's role
/// is "image-editor". A window created AFTER app launch may not start its Flutter
/// render loop (CVDisplayLink) — this animates continuously so the owner can
/// confirm on-device that the on-demand window both RENDERS and TICKS. Plan 2b
/// replaces this with the real Image Editor app.
class ImageEditorSpikeApp extends StatelessWidget {
  const ImageEditorSpikeApp({super.key});
  @override
  Widget build(BuildContext context) => const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: _SpikeHome(),
      );
}

class _SpikeHome extends StatefulWidget {
  const _SpikeHome();
  @override
  State<_SpikeHome> createState() => _SpikeHomeState();
}

class _SpikeHomeState extends State<_SpikeHome>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 2))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: const Color(0xFF101522),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RotationTransition(
                turns: _c,
                child: const Icon(Icons.sync, size: 96, color: Color(0xFF60A5FA)),
              ),
              const SizedBox(height: 24),
              AnimatedBuilder(
                animation: _c,
                builder: (_, _) => Text(
                  'render-loop spike — phase: ${(_c.value * 100).toStringAsFixed(0)}',
                  style: const TextStyle(color: Colors.white70, fontSize: 16),
                ),
              ),
            ],
          ),
        ),
      );
}
