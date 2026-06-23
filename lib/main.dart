import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:glimpr_pro/glimpr_pro.dart';
import 'capture/capture_bridge.dart';
import 'capture/direct_capture.dart';
import 'image_editor/image_editor_app.dart';
import 'output/clipboard.dart';
import 'output/filename.dart';
import 'overlay/overlay_app.dart';
import 'record/record_bridge.dart';
import 'record/record_controller.dart';
import 'settings/app_locale.dart';
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
  // Resolve the language choice once per engine boot (restart-effective);
  // every MaterialApp reads the resulting appLocaleOverride.
  await loadAppLocaleOverride();
  // Resolve Pro entitlement once per engine boot (offline; never blocks boot).
  // In the OSS build this is the no-op stub — every Pro feature stays locked.
  await ProRuntime.install();
  final role = await _getRole();
  if (role == 'overlay') {
    runApp(const OverlayApp());
    return;
  }
  if (role == 'image-editor') {
    runApp(const ImageEditorApp());
    return;
  }
  // Control engine only: register the global capture hotkey (default ⌘⌥1) via
  // the rebindable HotkeyService. The per-display overlay engines must NOT also
  // register it (one system hotkey). HotkeyService.start() never throws, so a
  // registration failure cannot block the app; the menu-bar Capture still works.
  final shortcutStore = ShortcutStore(Settings.instance.store);
  final bindings = await shortcutStore.all();
  final direct = DirectCapture();
  // Screen recording (macOS 15+): the controller registers its event
  // handlers up front; record actions no-op when the module is unavailable.
  final record = RecordController();
  final recordAvailable = await RecordBridge().isAvailable();
  // Reveal the warm Image-Editor window from a global hotkey (the control
  // engine owns the role channel that MainFlutterWindow handles).
  const control = MethodChannel('glimpr/role');
  void dispatchAction(String actionKey) {
    switch (actionKey) {
      case kCaptureAreaKey:
        CaptureBridge().beginCapture();
      case kCaptureScreenKey:
        direct.screen();
      case kCaptureWindowKey:
        direct.window();
      case kCaptureLastRegionKey:
        direct.lastRegion();
      case kOpenEditorKey:
        control.invokeMethod('openImageEditor');
      case kOpenEditorClipboardKey:
        control.invokeMethod('openImageEditorClipboard');
      case kPinAreaKey:
        // Capture a region straight to a floating pin (the overlay session
        // runs {pin} only, ignoring the configured after-capture flow).
        CaptureBridge().beginCapture(pinOnly: true);
      case kPinClipboardKey:
        _pinClipboard();
      case kRecordRegionKey:
        if (recordAvailable) record.toggle(kRecordModeRegion);
      case kRecordWindowKey:
        if (recordAvailable) record.toggle(kRecordModeWindow);
      case kRecordDisplayKey:
        if (recordAvailable) record.toggle(kRecordModeDisplay);
      case kRecordLastRegionKey:
        if (recordAvailable) record.toggle(kRecordModeLastRegion);
    }
  }

  // The menu-bar items fire actions over the same channel as the hotkeys; the
  // fallback keeps them working when an action's shortcut is unbound.
  final registrar = NativeHotkeyRegistrar()..fallback = dispatchAction;
  final hotkeyService = HotkeyService(
    registrar: registrar,
    bindings: bindings,
    onAction: dispatchAction,
  );
  await hotkeyService.start();
  runApp(SettingsApp(settings: Settings.instance, hotkeyService: hotkeyService));
}

/// Float the clipboard image as a centered pin window (⌘⌥6 — Snipaste's F3).
/// The image goes through a temp file so the native pin loads it like any
/// other source; a non-image clipboard surfaces a small native alert.
Future<void> _pinClipboard() async {
  Uint8List? bytes;
  try {
    bytes = await clipboardReadImage();
  } catch (_) {
    bytes = null;
  }
  if (bytes == null || bytes.isEmpty) {
    CaptureBridge().showError('No image in clipboard');
    return;
  }
  final file = File(
      '${Directory.systemTemp.path}/${screenshotFilename(DateTime.now(), 'png')}');
  await file.writeAsBytes(bytes);
  await CaptureBridge.pinImage(file.path);
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
