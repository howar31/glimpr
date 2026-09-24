import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/channels.dart';
import 'package:glimpr/platform_gate.dart';
import 'package:glimpr/settings/settings.dart';
import 'package:glimpr/settings/settings_app.dart';
import 'package:glimpr/update/update_check.dart';
import 'package:glimpr/update/updater.dart';

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

  testWidgets('official identity shows the plain version, no Dev marker',
      (tester) async {
    // appIsDev absent (null) = official / older native: the display MUST stay
    // byte-identical to the pre-marker About pane. Guards the production path.
    mockMethodChannel(kRoleChannel,
        handler: (c) => c.method == 'appVersion' ? '1.0.0 (1)' : null);
    await openAbout(tester, Settings(FakeStore()));
    expect(find.text('1.0.0 (1)'), findsOneWidget);
    expect(find.textContaining('Dev'), findsNothing);
  });

  testWidgets('dev identity appends the Dev marker to the version',
      (tester) async {
    mockMethodChannel(kRoleChannel, handler: (c) {
      if (c.method == 'appVersion') return '1.0.0 (1)';
      if (c.method == 'appIsDev') return true;
      return null;
    });
    await openAbout(tester, Settings(FakeStore()));
    expect(find.text('1.0.0 (1) Dev'), findsOneWidget);
    expect(find.text('1.0.0 (1)'), findsNothing); // replaced, not duplicated
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

  testWidgets('tray click with a known update opens the What\'s new page',
      (tester) async {
    final calls = mockMethodChannel(kRoleChannel,
        handler: (c) => c.method == 'appVersion' ? '1.0.0 (1)' : null);
    final updateCalls = mockMethodChannel(kUpdateChannel,
        handler: (c) => c.method == 'updateSupported' ? true : null);
    final store = FakeStore();
    final settings = Settings(store);
    await store.setString('update_latest_tag', 'v9.9.9');
    await store.setString('update_latest_url', 'https://example.test/rel');
    await store.setString(
        UpdateChecker.releasesKey,
        jsonEncode([
          {
            'tag': 'v9.9.9',
            'url': 'https://example.test/rel',
            'notes': '<!-- glimpr:notes lang=en -->\n- **Nine**: n\n<!-- /glimpr:notes -->'
          },
        ]));
    await tester.pumpWidget(SettingsApp(settings: settings));
    await tester.pumpAndSettle();
    await pushFromNative(kRoleChannel, 'trayCheckUpdates', null);
    await tester.pumpAndSettle();
    // Nothing installs or opens externally; the page is on top of About.
    expect(updateCalls, isEmpty);
    expect(calls.where((c) => c.method == 'openExternalUrl'), isEmpty);
    expect(find.text('Nine'), findsOneWidget);
    // A second click does not stack another copy.
    await pushFromNative(kRoleChannel, 'trayCheckUpdates', null);
    await tester.pumpAndSettle();
    expect(find.text('Nine'), findsOneWidget);
    // Back lands on About with the tappable update row.
    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();
    expect(find.text('Update available: v9.9.9'), findsOneWidget);
  });

  testWidgets('tray click with a known update but no notes lands on About',
      (tester) async {
    mockMethodChannel(kRoleChannel,
        handler: (c) => c.method == 'appVersion' ? '1.0.0 (1)' : null);
    final updateCalls = mockMethodChannel(kUpdateChannel,
        handler: (c) => c.method == 'updateSupported' ? true : null);
    final store = FakeStore();
    final settings = Settings(store);
    await store.setString('update_latest_tag', 'v9.9.9');
    await store.setString('update_latest_url', 'https://example.test/rel');
    await tester.pumpWidget(SettingsApp(settings: settings));
    await tester.pumpAndSettle();
    await pushFromNative(kRoleChannel, 'trayCheckUpdates', null);
    await tester.pumpAndSettle();
    expect(updateCalls, isEmpty);
    expect(find.text('Update available: v9.9.9'), findsOneWidget);
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
    // No URL opened; the About pane is showing (Sponsor row is About-only) and
    // a (clean) status push happened after the check resolved. The real
    // fetch is blocked by flutter_test's HttpOverrides, so the check yields
    // null -> the label resets to the idle "check" wording.
    expect(calls.where((c) => c.method == 'openExternalUrl'), isEmpty);
    expect(find.text('Sponsor'), findsOneWidget);
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

  const notesBody = """
Lead.

## What's new
<!-- glimpr:notes lang=en -->
- **Download progress**: percent and MB while it downloads.
<!-- /glimpr:notes -->
<details><summary>Chinese</summary>
<!-- glimpr:notes lang=zh -->
- **下載進度**：顯示百分比。
<!-- /glimpr:notes -->
</details>
""";

  testWidgets('persisted notes add a What\'s new card that opens the page',
      (tester) async {
    final calls = mockMethodChannel(kRoleChannel,
        handler: (c) => c.method == 'appVersion' ? '9.9.9 (1)' : null);
    final store = FakeStore();
    final settings = Settings(store);
    await store.setString('update_latest_tag', 'v9.9.9');
    await store.setString('update_latest_url', 'https://example.test/rel');
    await store.setString(
        UpdateChecker.releasesKey,
        jsonEncode([
          {'tag': 'v9.9.9', 'url': 'https://example.test/rel', 'notes': notesBody},
          // Older than the running version: never listed.
          {'tag': 'v9.9.8', 'url': 'u8', 'notes': notesBody},
        ]));
    await openAbout(tester, settings);
    // Up to date (same version): the card still describes the running release.
    expect(find.text("What's new in v9.9.9"), findsOneWidget);
    expect(find.text('Update available: v9.9.9'), findsNothing);
    await tester.tap(find.text("What's new in v9.9.9"));
    await tester.pumpAndSettle();
    expect(find.text('Download progress'), findsOneWidget);
    expect(find.text('percent and MB while it downloads.'), findsOneWidget);
    // One section: no version heading inside the page.
    expect(find.text('v9.9.9'), findsNothing);
    await tester.tap(find.text('View all releases on GitHub'));
    await tester.pump();
    final opened = calls.where((c) => c.method == 'openExternalUrl').toList();
    expect(opened, hasLength(1));
    expect((opened.single.arguments as Map)['url'],
        'https://github.com/howar31/glimpr/releases');
  });

  testWidgets('several pending releases list as sections, newest first',
      (tester) async {
    mockMethodChannel(kRoleChannel,
        handler: (c) => c.method == 'appVersion' ? '1.0.0 (1)' : null);
    final store = FakeStore();
    final settings = Settings(store);
    await store.setString('update_latest_tag', 'v1.2.0');
    await store.setString('update_latest_url', 'https://example.test/rel');
    await store.setString(
        UpdateChecker.releasesKey,
        jsonEncode([
          {
            'tag': 'v1.2.0',
            'url': 'u2',
            'notes': '<!-- glimpr:notes lang=en -->\n- **Two**: b\n<!-- /glimpr:notes -->'
          },
          // No tagged block: dropped, not shown as an empty section.
          {'tag': 'v1.1.5', 'url': 'u15', 'notes': '- **Untagged**: x'},
          {
            'tag': 'v1.1.0',
            'url': 'u1',
            'notes': '<!-- glimpr:notes lang=en -->\n- **One**: a\n<!-- /glimpr:notes -->'
          },
          // The running version itself: not pending.
          {
            'tag': 'v1.0.0',
            'url': 'u0',
            'notes': '<!-- glimpr:notes lang=en -->\n- **Zero**: z\n<!-- /glimpr:notes -->'
          },
        ]));
    await openAbout(tester, settings);
    expect(find.text("What's new from v1.1.0 to v1.2.0"), findsOneWidget);
    await tester.tap(find.text("What's new from v1.1.0 to v1.2.0"));
    await tester.pumpAndSettle();
    expect(find.text('v1.2.0'), findsOneWidget);
    expect(find.text('v1.1.0'), findsOneWidget);
    expect(find.text('Two'), findsOneWidget);
    expect(find.text('One'), findsOneWidget);
    expect(find.text('Untagged'), findsNothing);
    expect(find.text('Zero'), findsNothing);
    // Newest first.
    final two = tester.getTopLeft(find.text('Two'));
    final one = tester.getTopLeft(find.text('One'));
    expect(two.dy, lessThan(one.dy));
  });

  testWidgets('no persisted notes: no What\'s new card', (tester) async {
    mockMethodChannel(kRoleChannel,
        handler: (c) => c.method == 'appVersion' ? '1.0.0 (1)' : null);
    final store = FakeStore();
    final settings = Settings(store);
    await store.setString('update_latest_tag', 'v9.9.9');
    await store.setString('update_latest_url', 'https://example.test/rel');
    await openAbout(tester, settings);
    expect(find.textContaining("What's new"), findsNothing);
  });
  testWidgets('a resident poll hit refreshes the open About pane in place',
      (tester) async {
    // The control engine's poll (main.dart) persists the check and publishes
    // the result on a ValueNotifier the Settings UI listens to, so the About
    // row and the What's-new card follow the tray without a manual refresh.
    final calls = mockMethodChannel(kRoleChannel,
        handler: (c) => c.method == 'appVersion' ? '1.0.0 (1)' : null);
    final store = FakeStore();
    final settings = Settings(store);
    final feed = ValueNotifier<UpdateCheckResult?>(null);
    await tester.pumpWidget(SettingsApp(settings: settings, updateFeed: feed));
    await tester.pumpAndSettle();
    await tester.tap(find.text('About'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Update available'), findsNothing);
    expect(find.textContaining("What's new"), findsNothing);
    // What UpdateChecker._check writes before the poll's onNewer fires.
    const release = ReleaseInfo(
        tag: 'v9.9.9',
        url: 'https://example.test/rel',
        notes:
            '<!-- glimpr:notes lang=en -->\n- **Nine**: n\n<!-- /glimpr:notes -->');
    await store.setString('update_latest_tag', release.tag);
    await store.setString('update_latest_url', release.url);
    await store.setString(
        UpdateChecker.releasesKey, jsonEncode([release.toJson()]));
    feed.value = const UpdateCheckResult(
        latestTag: 'v9.9.9',
        url: 'https://example.test/rel',
        isNewer: true,
        releases: [release]);
    await tester.pumpAndSettle();
    expect(find.text('Update available: v9.9.9'), findsOneWidget);
    expect(find.text("What's new in v9.9.9"), findsOneWidget);
    // The tray click now routes to the What's-new page (the Dart side knows
    // about the update), not to a second manual check.
    await pushFromNative(kRoleChannel, 'trayCheckUpdates', null);
    await tester.pumpAndSettle();
    expect(find.text('Nine'), findsOneWidget);
    expect(calls.where((c) => c.method == 'appVersion').length,
        lessThanOrEqualTo(2));
  });
}
