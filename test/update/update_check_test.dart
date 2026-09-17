import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/update/update_check.dart';

import '../support/fake_store.dart';

void main() {
  group('isNewer', () {
    test('newer patch/minor/major', () {
      expect(UpdateChecker.isNewer('1.0.0 (1)', 'v1.0.1'), isTrue);
      expect(UpdateChecker.isNewer('1.0.0 (1)', 'v1.1.0'), isTrue);
      expect(UpdateChecker.isNewer('1.9.9 (1)', 'v2.0.0'), isTrue);
    });
    test('equal or older is not newer', () {
      expect(UpdateChecker.isNewer('1.0.0 (1)', 'v1.0.0'), isFalse);
      expect(UpdateChecker.isNewer('1.2.0 (1)', 'v1.1.9'), isFalse);
    });
    test('tolerates missing v prefix and bare versions', () {
      expect(UpdateChecker.isNewer('1.0.0', '1.0.1'), isTrue);
    });
    test('malformed input is never newer', () {
      expect(UpdateChecker.isNewer('1.0.0 (1)', 'nightly'), isFalse);
      expect(UpdateChecker.isNewer('', 'v1.0.1'), isFalse);
      expect(UpdateChecker.isNewer('1.0.0 (1)', 'v1.0'), isFalse);
    });
  });

  group('UpdateChecker', () {
    late FakeStore store;
    late int fetchCalls;
    DateTime now = DateTime.utc(2026, 7, 9, 12);

    UpdateChecker make({(String, String)? latest}) {
      fetchCalls = 0;
      return UpdateChecker(
        store: store,
        fetchLatest: () async {
          fetchCalls++;
          return latest == null ? null : (latest.$1, latest.$2, '');
        },
        currentVersion: () async => '1.0.0 (1)',
        now: () => now,
      );
    }

    setUp(() {
      store = FakeStore();
      fetchCalls = 0;
      now = DateTime.utc(2026, 7, 9, 12);
    });

    test('first launch checks and persists the newer release', () async {
      final c = make(latest: ('v1.2.0', 'https://example.test/rel'));
      final r = await c.maybeCheck();
      expect(r!.isNewer, isTrue);
      expect(r.latestTag, 'v1.2.0');
      expect(fetchCalls, 1);
      expect(await store.getString('update_latest_tag'), 'v1.2.0');
      expect(await store.getString('update_latest_url'),
          'https://example.test/rel');
      expect(await store.getInt('update_last_check_ms'),
          now.millisecondsSinceEpoch);
    });

    test('persists the notes body alongside the tag', () async {
      final c = UpdateChecker(
        store: store,
        fetchLatest: () async => ('v1.2.0', 'u', '## What\'s new\n- **A**: b'),
        currentVersion: () async => '1.0.0 (1)',
        now: () => now,
      );
      final r = await c.maybeCheck();
      expect(r!.notes, contains('**A**'));
      expect(await store.getString('update_latest_notes'), r.notes);
    });

    test('throttles within 6h, checks again after', () async {
      final c = make(latest: ('v1.0.0', 'u'));
      await c.maybeCheck();
      expect(fetchCalls, 1);
      now = now.add(const Duration(hours: 5));
      expect(await c.maybeCheck(), isNull);
      expect(fetchCalls, 1); // throttled
      now = now.add(const Duration(hours: 2));
      await c.maybeCheck();
      expect(fetchCalls, 2);
      expect(UpdateChecker.throttle, const Duration(hours: 6));
    });

    test('disabled: no fetch, returns null', () async {
      await store.setBool('update_check_enabled', false);
      final c = make(latest: ('v9.9.9', 'u'));
      expect(await c.maybeCheck(), isNull);
      expect(fetchCalls, 0);
    });

    test('fetch failure returns null but still stamps the attempt', () async {
      final c = make(latest: null);
      expect(await c.maybeCheck(), isNull);
      expect(await store.getInt('update_last_check_ms'),
          now.millisecondsSinceEpoch);
    });

    test('checkNow bypasses the throttle', () async {
      final c = make(latest: ('v1.0.1', 'u'));
      await c.maybeCheck();
      final r = await c.checkNow();
      expect(r!.isNewer, isTrue);
      expect(fetchCalls, 2);
    });

    test('up-to-date result is not newer and refreshes the stored tag',
        () async {
      await store.setString('update_latest_tag', 'v0.9.0');
      final c = make(latest: ('v1.0.0', 'u'));
      final r = await c.checkNow();
      expect(r!.isNewer, isFalse);
      expect(await store.getString('update_latest_tag'), 'v1.0.0');
    });
  });

  group('startUpdatePolling', () {
    // testWidgets for its fake zone: Timer.periodic follows tester.pump, and
    // the injected `now` is advanced alongside it, so six hours pass in no
    // real time.
    testWidgets('checks at once, then only when the throttle has elapsed',
        (tester) async {
      final store = FakeStore();
      var fetchCalls = 0;
      final hits = <String>[];
      var now = DateTime.utc(2026, 7, 9, 12);
      final checker = UpdateChecker(
        store: store,
        fetchLatest: () async {
          fetchCalls++;
          return ('v9.9.9', 'u', '');
        },
        currentVersion: () async => '1.0.0 (1)',
        now: () => now,
      );
      final timer = startUpdatePolling(checker, (r) => hits.add(r.latestTag),
          interval: const Duration(minutes: 15));
      await tester.pump();
      expect(fetchCalls, 1);
      expect(hits, ['v9.9.9']);
      // Ticks inside the throttle window stay silent.
      now = now.add(const Duration(hours: 5, minutes: 50));
      await tester.pump(const Duration(hours: 5, minutes: 50));
      expect(fetchCalls, 1);
      // The first tick past the window checks again.
      now = now.add(const Duration(minutes: 20));
      await tester.pump(const Duration(minutes: 20));
      expect(fetchCalls, 2);
      expect(hits, ['v9.9.9', 'v9.9.9']);
      timer.cancel();
    });
  });
}
