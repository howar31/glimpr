import 'package:flutter/widgets.dart';
import 'overlay_app.dart';

/// Dedicated entrypoint for the per-display overlay engines. Native runs each
/// overlay FlutterEngine with `run(withEntrypoint: "overlayMain")`.
@pragma('vm:entry-point')
void overlayMain() => runApp(const OverlayApp());
