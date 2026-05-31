import 'package:flutter/material.dart';

/// Root of an overlay engine. Transparent by default; renders the frozen-image
/// canvas only after the native side pushes `onCaptureReady` (wired in Task 5).
class OverlayApp extends StatelessWidget {
  const OverlayApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(scaffoldBackgroundColor: Colors.transparent),
      // Transparent host; Task 5 replaces this with the live overlay canvas.
      home: const SizedBox.expand(),
    );
  }
}
