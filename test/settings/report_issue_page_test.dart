import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/settings/licenses_page.dart' show glimprLicenseSurface;
import 'package:glimpr/settings/report_issue_page.dart';
import 'package:glimpr/theme/glimpr_theme.dart';

import '../support/localized_app.dart';

void main() {
  group('buildIssueUrl', () {
    test('prefills the diagnostics form field, URL-encoded', () {
      final url = buildIssueUrl('Glimpr 1.0.0, macOS\nOS: x');
      expect(url, startsWith(kIssueFormUrl));
      expect(url, contains('&diagnostics=Glimpr+1.0.0%2C+macOS%0AOS%3A+x'));
    });

    test('leaves an empty or oversized snapshot out', () {
      expect(buildIssueUrl(''), kIssueFormUrl);
      expect(buildIssueUrl('x' * 1501), kIssueFormUrl);
    });
  });

  Future<void> pump(WidgetTester tester,
      {required Future<String> report,
      required List<String> opened,
      required List<String> copied}) async {
    await tester.pumpWidget(localizedApp(glimprLicenseSurface(
      GlimprTokens.dark,
      ReportIssueView(
        report: report,
        onOpenUrl: opened.add,
        copyText: (t) async => copied.add(t),
      ),
    )));
    await tester.pump();
  }

  testWidgets('shows the collecting placeholder, then the snapshot',
      (tester) async {
    final c = Completer<String>();
    await pump(tester, report: c.future, opened: [], copied: []);
    expect(find.text('Report an issue'), findsOneWidget);
    expect(find.text('Collecting…'), findsOneWidget);
    c.complete('Glimpr 1.0.0, macOS');
    await tester.pump(); // completion microtask
    await tester.pump(); // FutureBuilder rebuild
    expect(find.text('Collecting…'), findsNothing);
    expect(find.text('Glimpr 1.0.0, macOS'), findsOneWidget);
  });

  testWidgets('the GitHub button opens the prefilled form URL',
      (tester) async {
    final opened = <String>[];
    await pump(tester,
        report: Future.value('Glimpr 1.0.0, macOS'),
        opened: opened,
        copied: []);
    await tester.pump();
    await tester.tap(find.text('Open an issue on GitHub'));
    expect(opened, [buildIssueUrl('Glimpr 1.0.0, macOS')]);
  });

  testWidgets('copy puts the snapshot on the clipboard and relabels',
      (tester) async {
    final copied = <String>[];
    await pump(tester,
        report: Future.value('Glimpr 1.0.0, macOS'),
        opened: [],
        copied: copied);
    await tester.pump();
    await tester.tap(find.text('Copy diagnostics'));
    await tester.pump();
    expect(copied, ['Glimpr 1.0.0, macOS']);
    expect(find.text('Copied'), findsOneWidget);
  });
}
