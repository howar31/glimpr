import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/settings/app_locale.dart';

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
}
