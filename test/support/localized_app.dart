import 'package:flutter/material.dart';
import 'package:glimpr/l10n/gen/app_localizations.dart';

/// Wraps [home] in a MaterialApp carrying the app's localization delegates,
/// mirroring how the engine roots provide l10n in production.
Widget localizedApp(Widget home) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: home,
    );
