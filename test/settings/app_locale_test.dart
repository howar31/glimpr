import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:glimpr/channels.dart';
import 'package:glimpr/l10n/gen/app_localizations.dart';
import 'package:glimpr/platform_gate.dart';
import 'package:glimpr/settings/app_locale.dart';
import 'package:glimpr/settings/settings.dart';

import '../support/fake_store.dart';
import '../support/mock_channels.dart';

void main() {
  test('explicit choices map to locales; system maps to null', () {
    expect(localeOverrideFor('en'), const Locale('en'));
    expect(localeOverrideFor('zh'), const Locale('zh'));
    expect(localeOverrideFor('system'), isNull);
    expect(localeOverrideFor('garbage'), isNull);
  });

  test('any Chinese system locale resolves to the zh localization', () {
    const supported = [Locale('en'), Locale('zh')];
    Locale r(List<Locale> l) => resolveAppLocale(l, supported);
    expect(
      r(const [Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant')]),
      const Locale('zh'),
    );
    expect(r(const [Locale('zh', 'TW')]), const Locale('zh'));
    expect(r(const [Locale('zh', 'CN')]), const Locale('zh'));
    expect(r(const [Locale('ja'), Locale('zh')]), const Locale('zh'));
    expect(r(const [Locale('fr')]), const Locale('en'));
    expect(resolveAppLocale(null, supported), const Locale('en'));
  });

  group('live language change', () {
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      appLocaleOverride = null;
      appL10n = lookupAppLocalizations(const Locale('en'));
    });
    tearDown(() {
      appLocaleOverride = null;
      appL10n = lookupAppLocalizations(const Locale('en'));
      debugPlatformOverride = null;
    });

    test('a reload follows the stored choice and reports a change', () async {
      final settings = Settings(FakeStore());
      await settings.setAppLanguage('zh');
      expect(await loadAppLocaleOverride(settings), isTrue);
      expect(appLocaleOverride, const Locale('zh'));
      expect(appL10n.localeName, 'zh');
      // Nothing changed since: no rebuild needed.
      expect(await loadAppLocaleOverride(settings), isFalse);
      await settings.setAppLanguage('en');
      expect(await loadAppLocaleOverride(settings), isTrue);
      expect(appL10n.localeName, 'en');
    });

    test('Windows re-pushes the tray and recording labels', () async {
      debugPlatformOverride = TargetPlatform.windows;
      final role = mockMethodChannel(kRoleChannel);
      final record = mockMethodChannel(const MethodChannel('glimpr/record'));
      final settings = Settings(FakeStore());
      await settings.setAppLanguage('zh');
      await loadAppLocaleOverride(settings);
      syncNativeLanguage(languageChanged: true);
      await pumpEventQueue();
      final zh = lookupAppLocalizations(const Locale('zh'));
      final tray = role.singleWhere((c) => c.method == 'setTrayLabels');
      expect((tray.arguments as Map)['settings'], zh.traySettings);
      final strip = record.singleWhere((c) => c.method == 'setRecordLabels');
      expect((strip.arguments as Map)['finish'], zh.recordStripFinish);
      expect(role.where((c) => c.method == 'languageChanged'), isEmpty);
    });

    test('macOS asks the native side to re-read the choice', () async {
      debugPlatformOverride = TargetPlatform.macOS;
      final role = mockMethodChannel(kRoleChannel);
      syncNativeLanguage(); // boot: native already read it
      await pumpEventQueue();
      expect(role, isEmpty);
      syncNativeLanguage(languageChanged: true);
      await pumpEventQueue();
      expect(role.single.method, 'languageChanged');
    });
  });
}
