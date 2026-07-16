import 'dart:async' show unawaited;
import 'dart:io';
import '../../platform_gate.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:glimpr_pro/glimpr_pro.dart';
import 'capture/capture_bridge.dart';
import 'capture/direct_capture.dart';
import 'channels.dart';
import 'gif_editor/gif_editor_app.dart';
import 'image_editor/image_editor_app.dart';
import 'output/clipboard.dart';
import 'output/deliver.dart' show effectiveSaveDir;
import 'output/filename.dart';
import 'output/flow.dart' show openFolderInFileManager;
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
import 'shortcuts/windows_hotkey_registrar.dart';
import 'update/update_check.dart';

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
  if (role == 'gif-editor') {
    runApp(const GifEditorApp());
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
  // Launch-time update check (silent, 24h-throttled, Settings-toggleable).
  // Fire-and-forget: never blocks boot; failures are silent by design. A hit
  // flips the tray item to its "update available" label right away (the
  // Settings UI seeds itself from the persisted keys separately).
  unawaited(() async {
    final r = await UpdateChecker(
      store: Settings.instance.store,
      fetchLatest: defaultFetchLatest,
      currentVersion: () async =>
          await kRoleChannel.invokeMethod<String>('appVersion') ?? '',
    ).maybeCheckOnLaunch();
    if (r != null && r.isNewer) {
      unawaited(kRoleChannel.invokeMethod('setUpdateStatus', {
        'available': true,
        'label': appL10n.settingsAboutUpdateAvailable(r.latestTag),
      }).catchError((_) {}));
    }
  }());
  // Reveal the warm Image-Editor window from a global hotkey (the control
  // engine owns the role channel that MainFlutterWindow handles).
  const control = kRoleChannel;
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
      case kOpenGifEditorKey:
        control.invokeMethod('openGifEditor');
      case kOpenGifEditorClipboardKey:
        control.invokeMethod('openGifEditorClipboard');
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
      case 'menu.openSaveFolder':
        _openSaveFolder();
    }
  }

  // The menu-bar / tray items fire actions over the same channel as the hotkeys;
  // the fallback keeps them working when an action's shortcut is unbound. The
  // registrar is platform-specific: macOS uses Carbon, Windows uses Win32
  // RegisterHotKey (the macOS one is unchanged from before).
  final HotkeyRegistrar registrar = platformIsWindows
      ? (WindowsHotkeyRegistrar()..fallback = dispatchAction)
      : (NativeHotkeyRegistrar()..fallback = dispatchAction);
  final hotkeyService = HotkeyService(
    registrar: registrar,
    bindings: bindings,
    onAction: dispatchAction,
  );
  await hotkeyService.start();
  // ShareX-style: if a stored global hotkey couldn't be registered at boot (the
  // combo is reserved / already taken by another app), warn the user once so
  // they go check Settings. Windows-only in practice — macOS Carbon can't detect
  // conflicts, so failedActions is always empty there.
  final failedHotkeys = hotkeyService.failedActions;
  if (failedHotkeys.isNotEmpty) {
    final l = appL10n;
    final lines = failedHotkeys.map((k) {
      final b = bindings[k] ?? defaultBindingFor(k);
      // Conflicts only surface on Windows (macOS Carbon can't detect them).
      final combo = b?.label(TargetPlatform.windows) ?? '';
      return '• ${globalActionLabel(l, k)}  ($combo)';
    }).join('\n');
    CaptureBridge().showError('${l.shortcutsConflictWarning}\n\n$lines');
  }

  // Windows: push the localized tray-menu labels to native. The runner C++ is
  // ASCII-only (cp950), so it cannot hold the zh strings — Dart owns l10n and
  // sends them. Global-action items reuse the Shortcuts-pane action labels;
  // menu-only items use dedicated keys. Sent once at boot (restart-effective).
  if (platformIsWindows) {
    final l = appL10n;
    control.invokeMethod('setTrayLabels', <String, String>{
      'captureArea': globalActionLabel(l, kCaptureAreaKey),
      'captureWindow': globalActionLabel(l, kCaptureWindowKey),
      'captureScreen': globalActionLabel(l, kCaptureScreenKey),
      'captureLast': globalActionLabel(l, kCaptureLastRegionKey),
      'pinArea': globalActionLabel(l, kPinAreaKey),
      'pinClipboard': globalActionLabel(l, kPinClipboardKey),
      'recordRegion': globalActionLabel(l, kRecordRegionKey),
      'recordWindow': globalActionLabel(l, kRecordWindowKey),
      'recordDisplay': globalActionLabel(l, kRecordDisplayKey),
      'recordLast': globalActionLabel(l, kRecordLastRegionKey),
      'openEditor': globalActionLabel(l, kOpenEditorKey),
      'openEditorClipboard': globalActionLabel(l, kOpenEditorClipboardKey),
      'gifEditor': l.trayOpenGifEditor,
      'gifEditorClipboard': globalActionLabel(l, kOpenGifEditorClipboardKey),
      'openRecent': l.trayOpenRecent,
      'clearRecent': l.trayClearRecent,
      'openSaveFolder': l.trayOpenSaveFolder,
      'checkUpdates': l.settingsAboutCheckUpdates,
      'about': l.trayAbout,
      'settings': l.traySettings,
      'quit': l.trayQuit,
      // Not a menu item: the tray tooltip while the recording-finalize pulse
      // runs (that pulse is native-initiated, so it cannot ride a channel arg).
      'processingRecording': l.trayProcessingRecording,
    }).catchError((_) {});
    // Push the localized recording-strip / countdown labels to native for the
    // same reason: the runner C++ is ASCII-only (cp950), so Dart owns l10n and
    // the native chrome sizes its buttons to the longest label per language.
    const MethodChannel('glimpr/record')
        .invokeMethod('setRecordLabels', <String, String>{
      'finish': l.recordStripFinish,
      'pause': l.recordStripPause,
      'resume': l.recordStripResume,
      'abort': l.recordStripAbort,
      'confirm': l.recordStripConfirm,
      'frames': l.recordStripFrames,
      'countdownCancel': l.recordCountdownCancel,
    }).catchError((_) {});
  }

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
    CaptureBridge().showError(appL10n.errorNoImageInClipboard);
    return;
  }
  final file = File(
      '${Directory.systemTemp.path}/${screenshotFilename(DateTime.now(), 'png')}');
  await file.writeAsBytes(bytes);
  await CaptureBridge.pinImage(file.path);
}

/// Open the configured save folder (Windows tray "Open Save Folder"). Reads the
/// stored save directory (falling back to the platform default the save leg uses)
/// and reveals it in the file manager.
Future<void> _openSaveFolder() async {
  final configured = resolveSaveDir(await Settings.instance.getSaveDirectory());
  final dir = effectiveSaveDir(configured);
  try {
    await dir.create(recursive: true); // ensure it exists before opening
  } catch (_) {}
  await openFolderInFileManager(dir.path);
}

/// Resolves this engine's role. The native handler is registered synchronously
/// at controller creation, but retry a few times in case Dart wins the race;
/// default to the control engine if the channel never answers.
Future<String> _getRole() async {
  const channel = kRoleChannel;
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
