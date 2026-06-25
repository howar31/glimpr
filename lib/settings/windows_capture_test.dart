import 'package:flutter/material.dart';

import '../capture/capture_bridge.dart';
import '../capture/direct_capture.dart';

/// Temporary Windows-only capture trigger (Phase 6 S2a + S2b). Windows has no
/// global hotkeys or system tray yet (those land in S3), so these buttons
/// invoke the native capture paths directly: the S2a direct modes and the S2b
/// interactive freeze overlay. Removed when S3 brings the tray + global hotkeys.
class WindowsCaptureTest extends StatelessWidget {
  const WindowsCaptureTest({super.key});

  @override
  Widget build(BuildContext context) {
    final direct = DirectCapture();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Windows capture (dev)',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton(
                    onPressed: () => direct.screen(),
                    child: const Text('Capture display')),
                ElevatedButton(
                    onPressed: () => direct.window(),
                    child: const Text('Capture window')),
                ElevatedButton(
                    onPressed: () => direct.lastRegion(),
                    child: const Text('Capture last region')),
                FilledButton(
                    onPressed: () => CaptureBridge().beginCapture(),
                    child: const Text('Overlay capture (freeze)')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
