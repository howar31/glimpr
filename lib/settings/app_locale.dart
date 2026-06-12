import 'dart:ui';

import '../l10n/gen/app_localizations.dart';
import 'settings.dart';

/// Process-global AppLocalizations for code that runs ABOVE a MaterialApp
/// (e.g. the overlay root state composing captions/errors before its own
/// MaterialApp provides Localizations). Valid because the language is
/// restart-effective: it cannot change within a process lifetime. Defaults to
/// English until [loadAppLocaleOverride] resolves the real choice at boot.
AppLocalizations appL10n = lookupAppLocalizations(const Locale('en'));

/// The app-wide locale override, resolved ONCE at engine boot from the
/// Settings language choice ('system' | 'en' | 'zh'); null = follow the
/// system. The language applies on restart (native menus cannot re-localize
/// live), so a boot-time snapshot is correct by design. Every engine's
/// main() loads this before runApp.
Locale? appLocaleOverride;

Future<void> loadAppLocaleOverride() async {
  appLocaleOverride =
      localeOverrideFor(await Settings.instance.getAppLanguage());
  appL10n = lookupAppLocalizations(
    appLocaleOverride ??
        resolveAppLocale(
          PlatformDispatcher.instance.locales,
          AppLocalizations.supportedLocales,
        ),
  );
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
