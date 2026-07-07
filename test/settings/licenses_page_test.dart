import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/settings/licenses_page.dart';
import 'package:glimpr/theme/glimpr_theme.dart';

import '../support/localized_app.dart';

void main() {
  // Register a test license once so the browser has a package to render
  // (LicenseRegistry is process-global; adding once avoids duplicate entries).
  setUpAll(() {
    LicenseRegistry.addLicense(() async* {
      yield const LicenseEntryWithLineBreaks(
          ['GlimprTestPkg'], 'Test license text.');
    });
  });

  Future<void> pumpBrowser(WidgetTester tester) async {
    await tester.pumpWidget(localizedApp(
      glimprLicenseSurface(GlimprTokens.dark, const LicensesView()),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('renders the header + a package row from the registry',
      (tester) async {
    await pumpBrowser(tester);
    // The shared settings header title.
    expect(find.text('Licenses & acknowledgements'), findsOneWidget);
    // The registered package appears as a master-list row.
    expect(find.text('GlimprTestPkg'), findsOneWidget);
  });

  testWidgets('tapping a package pushes its license-text detail page',
      (tester) async {
    await pumpBrowser(tester);
    await tester.tap(find.text('GlimprTestPkg'));
    await tester.pumpAndSettle();
    // The detail view shows the license paragraphs; the header now names the
    // package (the master row is offstage under the pushed route).
    expect(find.text('Test license text.'), findsOneWidget);
    expect(find.text('GlimprTestPkg'), findsOneWidget);

    // The back chevron pops to the master list.
    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();
    expect(find.text('Test license text.'), findsNothing);
    expect(find.text('Licenses & acknowledgements'), findsOneWidget);
  });
}
