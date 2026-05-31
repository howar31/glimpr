import 'package:flutter/material.dart';
import 'ui/capture_screen.dart';

void main() => runApp(const GlimprApp());

class GlimprApp extends StatelessWidget {
  const GlimprApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Glimpr',
        theme: ThemeData(useMaterial3: true),
        home: const CaptureScreen(),
      );
}
