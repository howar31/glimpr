import 'dart:io';
import 'package:flutter/material.dart';
import '../capture/capture_bridge.dart';
import '../capture/captured_display.dart';
import '../imaging/crop.dart';
import '../output/filename.dart';
import '../output/saver.dart';
import 'marquee.dart';

class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key});
  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  final _bridge = CaptureBridge();
  CapturedDisplay? _display;
  String _status = 'Press Capture.';
  final List<int> _latenciesMs = [];

  Future<void> _capture() async {
    final sw = Stopwatch()..start();
    try {
      final displays = await _bridge.captureAllDisplays();
      sw.stop();
      _latenciesMs.add(sw.elapsedMilliseconds);
      final chosen =
          displays.firstWhere((d) => d.isCursorDisplay, orElse: () => displays.first);
      setState(() {
        _display = chosen;
        _status = 'Captured ${displays.length} display(s) in '
            '${sw.elapsedMilliseconds} ms (p50 ${_p(50)} / p99 ${_p(99)} ms). '
            'Drag to select on the image below.';
      });
    } on CaptureException catch (e) {
      sw.stop();
      setState(() => _status = '${e.code}: ${e.message}');
    }
  }

  int _p(int pct) {
    if (_latenciesMs.isEmpty) return 0;
    final sorted = [..._latenciesMs]..sort();
    final idx = ((pct / 100) * (sorted.length - 1)).round();
    return sorted[idx];
  }

  Future<void> _onSelected(Rect localOnScreen, Size renderedSize) async {
    final d = _display!;
    final fit = d.width / renderedSize.width;
    final logical = Rect.fromLTWH(
      localOnScreen.left * fit,
      localOnScreen.top * fit,
      localOnScreen.width * fit,
      localOnScreen.height * fit,
    );
    final png = cropToSelection(
      pngBytes: d.pngBytes,
      scaleFactor: d.scaleFactor,
      selection: logical,
    );
    final dir = Directory('${Platform.environment['HOME']}/Pictures/Glimpr');
    final path = await saveBytes(
      dir: dir,
      fileName: screenshotFilename(DateTime.now(), 'png'),
      bytes: png,
    );
    setState(() => _status = 'Saved: $path');
  }

  @override
  Widget build(BuildContext context) {
    final d = _display;
    return Scaffold(
      appBar: AppBar(title: const Text('Glimpr — Phase 1 capture spike')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              FilledButton(onPressed: _capture, child: const Text('Capture')),
              const SizedBox(width: 12),
              Expanded(child: Text(_status)),
            ]),
            const SizedBox(height: 12),
            if (d != null)
              Expanded(
                child: LayoutBuilder(builder: (context, constraints) {
                  final rendered = Size(constraints.maxWidth,
                      constraints.maxWidth * d.height / d.width);
                  return SingleChildScrollView(
                    child: SizedBox(
                      width: rendered.width,
                      height: rendered.height,
                      child: Marquee(
                        onSelected: (r) => _onSelected(r, rendered),
                        child: Image.memory(d.pngBytes,
                            width: rendered.width,
                            height: rendered.height,
                            fit: BoxFit.fill),
                      ),
                    ),
                  );
                }),
              ),
          ],
        ),
      ),
    );
  }
}
