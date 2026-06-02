import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'capture/capture_bridge.dart';
import 'overlay/overlay_app.dart';
import 'settings/settings.dart';
import 'settings/settings_app.dart';
import 'shell/hotkey.dart';

/// Every engine runs this same main(). The native side answers `glimpr/role`
/// with 'overlay' for the per-display overlay engines and 'control' for the
/// resident menu-bar engine, so we mount the right widget tree per engine.
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
    // A hotkey failure must not block the app; the menu-bar Capture still works.
  }
  runApp(SettingsApp(settings: Settings.instance));
}

/// Resolves this engine's role. The native handler is registered synchronously
/// at controller creation, but retry a few times in case Dart wins the race;
/// default to the control engine if the channel never answers.
Future<String> _getRole() async {
  const channel = MethodChannel('glimpr/role');
  for (var attempt = 0; attempt < 10; attempt++) {
    try {
      final role = await channel.invokeMethod<String>('getRole');
      if (role != null) return role;
    } on MissingPluginException {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    } catch (_) {
      break; // unexpected channel error — fall back to the control engine
    }
  }
  return 'control';
}
