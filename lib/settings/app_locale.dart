import 'dart:ui';

import 'package:flutter/services.dart';

import '../channels.dart';
import '../l10n/gen/app_localizations.dart';
import '../platform_gate.dart';
import '../shortcuts/shortcut_actions.dart';
import 'settings.dart';

/// Process-global AppLocalizations for code that runs ABOVE a MaterialApp
/// (e.g. the overlay root state composing captions/errors before its own
/// MaterialApp provides Localizations). Replaced by [loadAppLocaleOverride],
/// so read it at use time and never keep a copy. Defaults to English until
/// the first load at boot.
AppLocalizations appL10n = lookupAppLocalizations(const Locale('en'));

/// The app-wide locale override, resolved from the Settings language choice
/// ('system' | 'en' | 'zh'); null = follow the system. Every engine's main()
/// loads this before runApp and each root State passes it to its MaterialApp.
Locale? appLocaleOverride;

/// Resolve the language choice into [appLocaleOverride] + [appL10n]. Returns
/// true when either changed, so a root State can rebuild its MaterialApp. The
/// language applies without a restart: the Settings engine reloads right after
/// the picker writes, the other engines at their settings-reload points (a
/// new capture, the editor window regaining focus). On Windows the caller
/// reloads the settings cache first when another engine made the change.
Future<bool> loadAppLocaleOverride([Settings? settings]) async {
  final override =
      localeOverrideFor(await (settings ?? Settings.instance).getAppLanguage());
  final l10n = lookupAppLocalizations(
    override ??
        resolveAppLocale(
          PlatformDispatcher.instance.locales,
          AppLocalizations.supportedLocales,
        ),
  );
  final changed =
      override != appLocaleOverride || l10n.localeName != appL10n.localeName;
  appLocaleOverride = override;
  appL10n = l10n;
  return changed;
}

/// Push the strings the native side shows in the current language. Windows:
/// the runner C++ is ASCII-only (cp950) and cannot hold the zh strings, so
/// Dart owns l10n and sends the tray-menu and recording-strip labels (the
/// native chrome sizes its buttons to the longest label per language).
/// macOS: the native side keeps its own string pairs and re-reads the stored
/// choice when [languageChanged] is set. Control engine only: at boot and
/// after the language changes.
void syncNativeLanguage({bool languageChanged = false}) {
  if (!platformIsWindows) {
    if (languageChanged) {
      kRoleChannel.invokeMethod('languageChanged').catchError((_) {});
    }
    return;
  }
  final l = appL10n;
  // Global-action items reuse the Shortcuts-pane action labels; menu-only
  // items use dedicated keys.
  kRoleChannel.invokeMethod('setTrayLabels', <String, String>{
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

/// 'en' -> English, 'zh' -> Traditional Chinese (the only Chinese
/// localization), anything else -> null (follow the system).
Locale? localeOverrideFor(String setting) => switch (setting) {
      'en' => const Locale('en'),
      'zh' => const Locale('zh'),
      _ => null,
    };

/// System-locale resolution: any Chinese system locale (zh, zh-Hant, zh-TW,
/// zh-HK, zh-CN) resolves to the Traditional Chinese localization; everything
/// else falls back to English.
Locale resolveAppLocale(List<Locale>? locales, Iterable<Locale> supported) {
  for (final l in locales ?? const <Locale>[]) {
    if (l.languageCode == 'zh') return const Locale('zh');
    if (l.languageCode == 'en') return const Locale('en');
  }
  return const Locale('en');
}
