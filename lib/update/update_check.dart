import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../settings/settings_store.dart';

/// Release metadata from the GitHub "latest release" endpoint, compared
/// against the running app version. The check itself only notifies; the
/// download/install lives in updater.dart.
class UpdateCheckResult {
  const UpdateCheckResult(
      {required this.latestTag,
      required this.url,
      required this.isNewer,
      this.releases = const []});
  final String latestTag;
  final String url;
  final bool isNewer;

  /// The newest stable releases, newest first (the first is [latestTag]).
  /// Their notes bodies feed the About page's "What's new".
  final List<ReleaseInfo> releases;
}

/// One stable release as the check saw it. [notes] is the raw markdown
/// body ('' when absent); release_notes.dart extracts the tagged bullets.
class ReleaseInfo {
  const ReleaseInfo({required this.tag, required this.url, this.notes = ''});
  final String tag;
  final String url;
  final String notes;

  Map<String, String> toJson() => {'tag': tag, 'url': url, 'notes': notes};

  static ReleaseInfo? fromJson(Object? j) {
    if (j is! Map) return null;
    final tag = j['tag'];
    final url = j['url'];
    final notes = j['notes'];
    if (tag is! String || url is! String || tag.isEmpty) return null;
    return ReleaseInfo(tag: tag, url: url, notes: notes is String ? notes : '');
  }

  /// The persisted list (see [UpdateChecker.releasesKey]) back to objects;
  /// empty on malformed input.
  static List<ReleaseInfo> listFromJson(String? s) {
    if (s == null || s.isEmpty) return const [];
    try {
      final j = jsonDecode(s);
      if (j is! List) return const [];
      return [for (final e in j) ?fromJson(e)];
    } catch (_) {
      return const [];
    }
  }
}

/// How many stable releases the check keeps (one API page; the About page
/// lists the ones newer than the running version, GitHub has the rest).
const kReleaseHistory = 10;

class UpdateChecker {
  UpdateChecker({
    required this.store,
    required this.fetchReleases,
    required this.currentVersion,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final SettingsStore store;

  /// The newest stable releases, newest first, at most [kReleaseHistory];
  /// null on any failure (network, non-200, malformed body), empty when the
  /// repo has no stable release. Injected for tests.
  final Future<List<ReleaseInfo>?> Function() fetchReleases;

  /// The running version string as the role channel reports it: "x.y.z (b)".
  final Future<String> Function() currentVersion;

  final DateTime Function() _now;

  static const _kEnabled = 'update_check_enabled';
  static const _kLastCheckMs = 'update_last_check_ms';
  static const _kLatestTag = 'update_latest_tag';
  static const _kLatestUrl = 'update_latest_url';

  /// Settings key holding the JSON list of [ReleaseInfo] from the last
  /// successful check (newest first).
  static const releasesKey = 'update_releases';
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
    final releases = await fetchReleases();
    if (releases == null || releases.isEmpty) return null;
    final latest = releases.first;
    await store.setString(_kLatestTag, latest.tag);
    await store.setString(_kLatestUrl, latest.url);
    await store.setString(
        releasesKey, jsonEncode([for (final r in releases) r.toJson()]));
    return UpdateCheckResult(
        latestTag: latest.tag,
        url: latest.url,
        isNewer: isNewer(await currentVersion(), latest.tag),
        releases: releases);
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

/// Production fetcher: the GitHub releases list, newest first. Drafts never
/// reach an unauthenticated caller; prereleases (rc) are dropped here, so
/// the first entry is what `releases/latest` would return. One short-lived
/// connection; null on any failure.
Future<List<ReleaseInfo>?> defaultFetchReleases() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    // A few extra rows so rc entries in the window do not eat the quota.
    final req = await client.getUrl(Uri.parse(
        'https://api.github.com/repos/howar31/glimpr/releases?per_page=${kReleaseHistory + 5}'));
    req.headers.set(HttpHeaders.userAgentHeader, 'Glimpr');
    req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    final res = await req.close().timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;
    final body = await res.transform(utf8.decoder).join();
    return parseReleaseList(body);
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// Pure JSON -> stable releases, newest first, capped at [kReleaseHistory];
/// null on malformed input (unit-tested).
List<ReleaseInfo>? parseReleaseList(String body) {
  try {
    final json = jsonDecode(body);
    if (json is! List) return null;
    final out = <ReleaseInfo>[];
    for (final r in json) {
      if (r is! Map) continue;
      if (r['draft'] == true || r['prerelease'] == true) continue;
      final tag = r['tag_name'];
      final url = r['html_url'];
      final notes = r['body'];
      if (tag is! String || url is! String || tag.isEmpty) continue;
      out.add(ReleaseInfo(
          tag: tag, url: url, notes: notes is String ? notes : ''));
      if (out.length == kReleaseHistory) break;
    }
    return out;
  } catch (_) {
    return null;
  }
}
