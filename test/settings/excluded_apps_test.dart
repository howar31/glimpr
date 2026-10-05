import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/platform_gate.dart';
import 'package:glimpr/settings/excluded_apps.dart';
import 'package:glimpr/settings/settings.dart';
import 'package:glimpr/theme/glimpr_controls.dart';
import 'package:glimpr/theme/glimpr_theme.dart';

import '../support/fake_store.dart';
import '../support/localized_app.dart';

void main() {
  tearDown(() => debugPlatformOverride = null);

  group('stored form', () {
    test('round-trips entries, modes and order', () {
      const entries = [
        ExcludedEntry('com.example.chat'),
        ExcludedEntry('com.example.widget', ExcludeMode.screenshots),
        ExcludedEntry('com.example.player', ExcludeMode.recordings),
        ExcludedEntry('c:/apps/notes/notes.exe', ExcludeMode.blur),
      ];
      final raw = encodeExcludedApps(entries);
      expect(
        raw,
        'com.example.chat|com.example.widget?shot|com.example.player?rec|'
        'c:/apps/notes/notes.exe?blur',
      );
      expect(decodeExcludedApps(raw), entries);
    });

    test('drops blanks and duplicate ids', () {
      expect(decodeExcludedApps('a||b|a?rec| '),
          const [ExcludedEntry('a'), ExcludedEntry('b')]);
      expect(
        encodeExcludedApps(const [
          ExcludedEntry('a'),
          ExcludedEntry(''),
          ExcludedEntry('a', ExcludeMode.blur),
          ExcludedEntry('b'),
        ]),
        'a|b',
      );
    });

    test('an unset or empty value is an empty list', () {
      expect(decodeExcludedApps(null), isEmpty);
      expect(decodeExcludedApps(''), isEmpty);
    });

    test('an unknown mode reads as the default', () {
      expect(decodeExcludedApps('a?later'), const [ExcludedEntry('a')]);
    });

    test('separators inside an id cannot split it or forge a mode', () {
      expect(
        decodeExcludedApps(encodeExcludedApps(const [ExcludedEntry('a|b?rec')])),
        const [ExcludedEntry('abrec')],
      );
    });

    test('Settings persists the list and both switches', () async {
      final store = FakeStore();
      final s = Settings(store);
      expect(await s.getExcludedApps(), isEmpty);
      expect(await s.getExcludedAppsEnabled(), isTrue);
      expect(await s.getExcludeOwnWindows(), isFalse);
      await s.setExcludedApps(const [
        ExcludedEntry('one'),
        ExcludedEntry('two', ExcludeMode.recordings),
      ]);
      await s.setExcludeOwnWindows(true);
      expect(store.map['excluded_apps'], 'one|two?rec');
      expect(store.map['exclude_own_windows'], isTrue);
      expect(await s.getExcludedApps(), const [
        ExcludedEntry('one'),
        ExcludedEntry('two', ExcludeMode.recordings),
      ]);
    });
  });

  group('ExcludedApp.fromMap', () {
    test('falls back to the id when the name is missing', () {
      final a = ExcludedApp.fromMap({'id': 'com.example.x'})!;
      expect(a.name, 'com.example.x');
      expect(a.icon, isNull);
    });

    test('rejects entries without an id', () {
      expect(ExcludedApp.fromMap({'name': 'X'}), isNull);
      expect(ExcludedApp.fromMap('nope'), isNull);
    });
  });

  group('pane', () {
    const chat = ExcludedApp(id: 'com.example.chat', name: 'Chat');
    const widgetApp = ExcludedApp(id: 'com.example.widget', name: 'Widget');
    const browser = ExcludedApp(id: 'com.example.browser', name: 'Browser');

    Future<FakeStore> pump(
      WidgetTester tester, {
      Map<String, Object?>? seed,
      List<ExcludedApp> running = const [],
      List<ExcludedApp> installed = const [],
    }) async {
      await tester.binding.setSurfaceSize(const Size(900, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = FakeStore(seed);
      await tester.pumpWidget(localizedApp(
        Scaffold(
          body: GlimprTheme(
            tokens: GlimprTokens.dark,
            child: SingleChildScrollView(
              child: PrivacyPane(
                settings: Settings(store),
                listRunning: () async => running,
                resolve: (ids) async => [
                  for (final a in [...installed, ...running])
                    if (ids.contains(a.id)) a,
                ],
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return store;
    }

    Finder rowOf(String id) => find.byKey(ValueKey('privacy-app-$id'));
    Finder addOf(String id) => find.descendant(
        of: rowOf(id), matching: find.byIcon(Icons.add));
    Finder removeOf(String id) => find.descendant(
        of: rowOf(id), matching: find.byIcon(Icons.remove));

    testWidgets('stored apps show by resolved name, unknown ones by id',
        (tester) async {
      await pump(
        tester,
        seed: {'excluded_apps': 'com.example.chat|com.example.gone'},
        installed: const [chat],
      );
      expect(find.text('Chat'), findsOneWidget);
      expect(find.text('com.example.gone'), findsOneWidget);
      expect(removeOf('com.example.chat'), findsOneWidget);
      expect(find.byTooltip('Stop excluding'), findsNWidgets(2));
    });

    testWidgets('adding a running app excludes it', (tester) async {
      final store = await pump(tester, running: const [chat, widgetApp]);
      expect(find.text('No applications excluded'), findsOneWidget);
      expect(find.byTooltip('Exclude'), findsNWidgets(2));
      await tester.tap(addOf('com.example.widget'));
      await tester.pumpAndSettle();
      expect(store.map['excluded_apps'], 'com.example.widget');
      expect(removeOf('com.example.widget'), findsOneWidget);
      expect(addOf('com.example.chat'), findsOneWidget);
      expect(find.text('No applications excluded'), findsNothing);
    });

    testWidgets('removing an excluded app keeps its row for an undo',
        (tester) async {
      final store = await pump(
        tester,
        seed: {'excluded_apps': 'com.example.chat'},
        installed: const [chat],
      );
      await tester.tap(removeOf('com.example.chat'));
      await tester.pumpAndSettle();
      expect(store.map['excluded_apps'], '');
      // Not running, but still listed so the tap can be reversed.
      await tester.tap(addOf('com.example.chat'));
      await tester.pumpAndSettle();
      expect(store.map['excluded_apps'], 'com.example.chat');
    });

    testWidgets('the name filter narrows both groups', (tester) async {
      await pump(
        tester,
        seed: {'excluded_apps': 'com.example.chat'},
        running: const [chat, widgetApp, browser],
      );
      await tester.enterText(find.byType(TextField), 'wid');
      await tester.pumpAndSettle();
      expect(find.text('Widget'), findsOneWidget);
      expect(find.text('Browser'), findsNothing);
      expect(find.text('Chat'), findsNothing);
      expect(find.text('No matching applications'), findsOneWidget);
    });

    testWidgets('refresh adds applications started since the pane opened',
        (tester) async {
      final running = <ExcludedApp>[chat];
      await tester.binding.setSurfaceSize(const Size(900, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(localizedApp(
        Scaffold(
          body: GlimprTheme(
            tokens: GlimprTokens.dark,
            child: SingleChildScrollView(
              child: PrivacyPane(
                settings: Settings(FakeStore()),
                listRunning: () async => List.of(running),
                resolve: (ids) async => const [],
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Widget'), findsNothing);
      running.add(widgetApp);
      await tester.tap(find.byTooltip('Refresh'));
      await tester.pumpAndSettle();
      expect(find.text('Widget'), findsOneWidget);
    });

    testWidgets('an excluded app offers the scope choice on macOS',
        (tester) async {
      debugPlatformOverride = TargetPlatform.macOS;
      final store = await pump(
        tester,
        seed: {'excluded_apps': 'com.example.chat'},
        running: const [chat, widgetApp],
      );
      // Only the excluded row carries the choice.
      expect(find.text('Recordings'), findsOneWidget);
      expect(find.text('Blur'), findsNothing);
      await tester.tap(find.text('Recordings'));
      await tester.pumpAndSettle();
      expect(store.map['excluded_apps'], 'com.example.chat?rec');
      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();
      expect(store.map['excluded_apps'], 'com.example.chat');
    });

    testWidgets('an excluded app offers the cover style on Windows',
        (tester) async {
      debugPlatformOverride = TargetPlatform.windows;
      final store = await pump(
        tester,
        // A scope written on macOS reads as the default here.
        seed: {'excluded_apps': 'c:/apps/chat.exe?rec'},
        installed: const [ExcludedApp(id: 'c:/apps/chat.exe', name: 'Chat')],
      );
      expect(find.text('Recordings'), findsNothing);
      await tester.tap(find.text('Blur'));
      await tester.pumpAndSettle();
      expect(store.map['excluded_apps'], 'c:/apps/chat.exe?blur');
    });

    testWidgets('the Glimpr windows switch persists and defaults to off',
        (tester) async {
      final store = await pump(tester);
      final own = find.byType(GlassToggle).at(1);
      expect(tester.widget<GlassToggle>(own).value, isFalse);
      await tester.tap(own);
      await tester.pumpAndSettle();
      expect(store.map['exclude_own_windows'], isTrue);
    });

    testWidgets('the master switch persists and defaults to on',
        (tester) async {
      final store = await pump(tester, running: const [chat]);
      final master = find.byType(GlassToggle).first;
      expect(tester.widget<GlassToggle>(master).value, isTrue);
      await tester.tap(master);
      await tester.pumpAndSettle();
      expect(store.map['excluded_apps_enabled'], isFalse);
      expect(await Settings(store).getExcludedAppsEnabled(), isFalse);
    });

    testWidgets('the description follows the platform', (tester) async {
      debugPlatformOverride = TargetPlatform.windows;
      await pump(tester);
      expect(find.textContaining('blacked out or blurred'), findsOneWidget);
      debugPlatformOverride = TargetPlatform.macOS;
      await pump(tester);
      expect(find.textContaining('left out of screenshots and recordings'),
          findsOneWidget);
    });
  });
}
