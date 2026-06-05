import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'capture/capture_bridge.dart';
import 'capture/direct_capture.dart';
import 'image_editor/image_editor_spike.dart';
import 'overlay/overlay_app.dart';
import 'settings/settings.dart';
import 'settings/settings_app.dart';
import 'shortcuts/hotkey_registrar.dart';
import 'shortcuts/hotkey_service.dart';
import 'shortcuts/shortcut_actions.dart';
import 'shortcuts/shortcut_store.dart';

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
  if (role == 'image-editor') {
    runApp(const ImageEditorSpikeApp());
    return;
  }
  // Control engine only: register the global capture hotkey (default ⌘⌥1) via
  // the rebindable HotkeyService. The per-display overlay engines must NOT also
  // register it (one system hotkey). HotkeyService.start() never throws, so a
  // registration failure cannot block the app; the menu-bar Capture still works.
  final shortcutStore = ShortcutStore(Settings.instance.store);
  final bindings = await shortcutStore.all();
  final direct = DirectCapture();
  final hotkeyService = HotkeyService(
    registrar: HotkeyManagerRegistrar(),
    bindings: bindings,
    onAction: (actionKey) {
      switch (actionKey) {
        case kCaptureAreaKey:
          CaptureBridge().beginCapture();
        case kCaptureScreenKey:
          direct.screen();
        case kCaptureWindowKey:
          direct.window();
        case kCaptureLastRegionKey:
          direct.lastRegion();
      }
    },
  );
  await hotkeyService.start();
  runApp(SettingsApp(settings: Settings.instance, hotkeyService: hotkeyService));
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
