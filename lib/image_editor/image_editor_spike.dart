import 'package:flutter/material.dart';

/// TEMPORARY render-loop spike (Phase 5 Plan 2a). Mounted when the engine's role
/// is "image-editor". Tests an on-demand (post-launch) window two ways: (1) the
/// spinning icon / phase number test the IDLE vsync render loop; (2) the "TAP ME"
/// button tests whether a DISCRETE setState (tap + release, no dragging) repaints
/// — the behavior a mostly-static editor actually needs (commit-on-release shows
/// the result). Plan 2b replaces this with the real Image Editor app.
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
  int _taps = 0;

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
              // IDLE test: spins + climbs ONLY if the vsync render loop ticks.
              RotationTransition(
                turns: _c,
                child: const Icon(Icons.sync, size: 96, color: Color(0xFF60A5FA)),
              ),
              const SizedBox(height: 16),
              AnimatedBuilder(
                animation: _c,
                builder: (_, _) => Text(
                  'idle render loop — phase: ${(_c.value * 100).toStringAsFixed(0)}',
                  style: const TextStyle(color: Colors.white70, fontSize: 16),
                ),
              ),
              const SizedBox(height: 40),
              // DISCRETE test: does a tap (no dragging) repaint? This is what a
              // static editor needs — draw, release, the result must show.
              FilledButton(
                onPressed: () => setState(() => _taps++),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  child: Text('TAP ME', style: TextStyle(fontSize: 18)),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'discrete taps: $_taps',
                style: const TextStyle(color: Colors.white, fontSize: 22),
              ),
            ],
          ),
        ),
      );
}
