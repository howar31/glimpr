import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../settings/settings_store.dart';

/// Release metadata from the GitHub "latest release" endpoint, compared
/// against the running app version. The check itself only notifies; the
/// download/install lives in updater.dart.
class UpdateCheckResult {
  const UpdateCheckResult(
      {required this.latestTag, required this.url, required this.isNewer});
  final String latestTag;
  final String url;
  final bool isNewer;
}

class UpdateChecker {
  UpdateChecker({
    required this.store,
    required this.fetchLatest,
    required this.currentVersion,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final SettingsStore store;

  /// Returns (tagName, htmlUrl) of the latest stable release, or null on any
  /// failure (network, non-200, malformed body). Injected for tests.
  final Future<(String, String)?> Function() fetchLatest;

  /// The running version string as the role channel reports it: "x.y.z (b)".
  final Future<String> Function() currentVersion;

  final DateTime Function() _now;

  static const _kEnabled = 'update_check_enabled';
  static const _kLastCheckMs = 'update_last_check_ms';
  static const _kLatestTag = 'update_latest_tag';
  static const _kLatestUrl = 'update_latest_url';
  /// Minimum gap between automatic checks. Shared by the launch check and
  /// the resident poll, so a relaunch inside the window stays silent.
  static const throttle = Duration(hours: 6);

  Future<bool> enabled() async => (await store.getBool(_kEnabled)) ?? true;
  Future<void> setEnabled(bool v) => store.setBool(_kEnabled, v);

  /// Automatic check (launch + resident poll): silent, throttled to once
  /// per [throttle], null when disabled/throttled/failed.
  Future<UpdateCheckResult?> maybeCheck() async {
    if (!await enabled()) return null;
    final last = await store.getInt(_kLastCheckMs) ?? 0;
    final nowMs = _now().millisecondsSinceEpoch;
    if (nowMs - last < throttle.inMilliseconds) return null;
    return _check(nowMs);
  }

  /// Manual check from the About pane: bypasses the throttle.
  Future<UpdateCheckResult?> checkNow() async =>
      _check(_now().millisecondsSinceEpoch);

  Future<UpdateCheckResult?> _check(int nowMs) async {
    // Stamp the attempt first so a failing endpoint is not hammered on
    // every launch.
    await store.setInt(_kLastCheckMs, nowMs);
    final latest = await fetchLatest();
    if (latest == null) return null;
    final (tag, url) = latest;
    await store.setString(_kLatestTag, tag);
    await store.setString(_kLatestUrl, url);
    return UpdateCheckResult(
        latestTag: tag,
        url: url,
        isNewer: isNewer(await currentVersion(), tag));
  }

  /// Pure semver-triple compare; any parse failure means "not newer".
  static bool isNewer(String current, String latest) {
    final c = _triple(current);
    final l = _triple(latest);
    if (c == null || l == null) return false;
    for (var i = 0; i < 3; i++) {
      if (l[i] != c[i]) return l[i] > c[i];
    }
    return false;
  }

  static List<int>? _triple(String v) {
    var s = v.trim();
    final space = s.indexOf(' ');
    if (space != -1) s = s.substring(0, space); // drop " (build)"
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    final parts = s.split('.');
    if (parts.length != 3) return null;
    final nums = <int>[];
    for (final p in parts) {
      final n = int.tryParse(p);
      if (n == null) return null;
      nums.add(n);
    }
    return nums;
  }
}

/// Resident poll: runs [checker.maybeCheck] now and then every [interval],
/// calling [onNewer] for each hit. A short interval with the long throttle
/// (rather than one timer per throttle period) is deliberate: Dart timers do
/// not run while the machine sleeps, so a long timer wakes late; a short one
/// catches up within [interval] of waking. Returns the timer for disposal.
Timer startUpdatePolling(UpdateChecker checker,
    void Function(UpdateCheckResult r) onNewer,
    {Duration interval = const Duration(minutes: 15)}) {
  Future<void> tick() async {
    final r = await checker.maybeCheck();
    if (r != null && r.isNewer) onNewer(r);
  }

  unawaited(tick());
  return Timer.periodic(interval, (_) => unawaited(tick()));
}

/// Production fetcher: GitHub latest-release endpoint (excludes drafts and
/// prereleases). One short-lived connection; null on any failure.
Future<(String, String)?> defaultFetchLatest() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.getUrl(Uri.parse(
        'https://api.github.com/repos/howar31/glimpr/releases/latest'));
    req.headers.set(HttpHeaders.userAgentHeader, 'Glimpr');
    req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    final res = await req.close().timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;
    final body = await res.transform(utf8.decoder).join();
    final json = jsonDecode(body);
    final tag = json['tag_name'];
    final url = json['html_url'];
    if (tag is! String || url is! String || tag.isEmpty) return null;
    return (tag, url);
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}
