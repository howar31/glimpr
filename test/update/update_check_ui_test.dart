import 'package:flutter/material.dart';
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

  testWidgets('idle About header offers the refresh affordance', (tester) async {
    mockMethodChannel(kRoleChannel,
        handler: (c) => c.method == 'appVersion' ? '1.0.0 (1)' : null);
    await openAbout(tester, Settings(FakeStore()));
    // The check lives next to the version number (a refresh icon), not among
    // the About links; idle shows no status line.
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    expect(find.textContaining('Update available'), findsNothing);
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
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    expect(find.textContaining('Update available'), findsNothing);
  });

  testWidgets('a persisted newer release pushes the tray update status',
      (tester) async {
    final calls = mockMethodChannel(kRoleChannel,
        handler: (c) => c.method == 'appVersion' ? '1.0.0 (1)' : null);
    final store = FakeStore();
    final settings = Settings(store);
    await store.setString('update_latest_tag', 'v9.9.9');
    await store.setString('update_latest_url', 'https://example.test/rel');
    await openAbout(tester, settings);
    final push = calls.where((c) => c.method == 'setUpdateStatus').toList();
    expect(push, isNotEmpty);
    final args = (push.last.arguments as Map).cast<String, Object?>();
    expect(args['available'], isTrue);
    expect(args['label'], 'Update available: v9.9.9');
  });

  testWidgets('tray click with a known update opens the release page',
      (tester) async {
    final calls = mockMethodChannel(kRoleChannel,
        handler: (c) => c.method == 'appVersion' ? '1.0.0 (1)' : null);
    final store = FakeStore();
    final settings = Settings(store);
    await store.setString('update_latest_tag', 'v9.9.9');
    await store.setString('update_latest_url', 'https://example.test/rel');
    await openAbout(tester, settings);
    await pushFromNative(kRoleChannel, 'trayCheckUpdates', null);
    await tester.pump();
    final opened = calls.where((c) => c.method == 'openExternalUrl').toList();
    expect(opened, hasLength(1));
    expect((opened.single.arguments as Map)['url'], 'https://example.test/rel');
  });

  testWidgets('tray click without a known update lands on About and checks',
      (tester) async {
    final calls = mockMethodChannel(kRoleChannel,
        handler: (c) => c.method == 'appVersion' ? '1.0.0 (1)' : null);
    final settings = Settings(FakeStore());
    // Stay on the General pane; the tray call must deep-link to About itself.
    await tester.pumpWidget(SettingsApp(settings: settings));
    await tester.pumpAndSettle();
    await pushFromNative(kRoleChannel, 'trayCheckUpdates', null);
    await tester.pumpAndSettle();
    // No URL opened; the About pane is showing (Ko-fi row is About-only) and
    // a (clean) status push happened after the check resolved. The real
    // fetch is blocked by flutter_test's HttpOverrides, so the check yields
    // null -> the label resets to the idle "check" wording.
    expect(calls.where((c) => c.method == 'openExternalUrl'), isEmpty);
    expect(find.text('Support'), findsOneWidget);
    final push = calls.where((c) => c.method == 'setUpdateStatus').toList();
    expect(push, isNotEmpty);
    final args = (push.last.arguments as Map).cast<String, Object?>();
    expect(args['available'], isFalse);
    expect(args['label'], 'Check for updates');
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
