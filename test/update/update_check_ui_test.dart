import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/channels.dart';
import 'package:glimpr/platform_gate.dart';
import 'package:glimpr/settings/settings.dart';
import 'package:glimpr/settings/settings_app.dart';

import '../support/fake_store.dart';
import '../support/mock_channels.dart';

// The About pane's update row, driven by the persisted launch-check result
// (the manual-check tap is NOT exercised here: it would hit the real network
// fetcher, which flutter_test's HttpOverrides block — core logic is covered
// by update_check_test.dart).
void main() {
  setUp(() {
    debugPlatformOverride = TargetPlatform.macOS;
  });
  tearDown(() {
    debugPlatformOverride = null;
  });

  Future<void> openAbout(WidgetTester tester, Settings settings) async {
    await tester.pumpWidget(SettingsApp(settings: settings));
    await tester.pumpAndSettle();
    await tester.tap(find.text('About'));
    await tester.pumpAndSettle();
  }

  testWidgets('idle About row offers a manual update check', (tester) async {
    mockMethodChannel(kRoleChannel,
        handler: (c) => c.method == 'appVersion' ? '1.0.0 (1)' : null);
    await openAbout(tester, Settings(FakeStore()));
    expect(find.text('Check for updates'), findsOneWidget);
  });

  testWidgets('persisted newer release shows the update badge row',
      (tester) async {
    mockMethodChannel(kRoleChannel,
        handler: (c) => c.method == 'appVersion' ? '1.0.0 (1)' : null);
    final store = FakeStore();
    final settings = Settings(store);
    await store.setString('update_latest_tag', 'v9.9.9');
    await store.setString('update_latest_url', 'https://example.test/rel');
    await openAbout(tester, settings);
    expect(find.text('Update available: v9.9.9'), findsOneWidget);
  });

  testWidgets('persisted older tag does not show a badge', (tester) async {
    mockMethodChannel(kRoleChannel,
        handler: (c) => c.method == 'appVersion' ? '1.0.0 (1)' : null);
    final store = FakeStore();
    final settings = Settings(store);
    await store.setString('update_latest_tag', 'v0.9.0');
    await store.setString('update_latest_url', 'https://example.test/rel');
    await openAbout(tester, settings);
    expect(find.text('Check for updates'), findsOneWidget);
  });

  testWidgets('Advanced pane toggle persists update_check_enabled',
      (tester) async {
    mockMethodChannel(kRoleChannel,
        handler: (c) => c.method == 'appVersion' ? '1.0.0 (1)' : null);
    final store = FakeStore();
    final settings = Settings(store);
    await tester.pumpWidget(SettingsApp(settings: settings));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Advanced'));
    await tester.pumpAndSettle();
    final toggleLabel = find.text('Check for updates automatically');
    await tester.scrollUntilVisible(
      toggleLabel,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    // The row's GlassToggle sits in the same SettingRow; tapping the toggle
    // flips and persists the setting.
    final toggle = find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == 'GlassToggle');
    await tester.tap(toggle.last);
    await tester.pumpAndSettle();
    expect(await store.getBool('update_check_enabled'), isFalse);
  });
}
