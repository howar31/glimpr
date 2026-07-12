import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../platform_gate.dart';

/// One-click self-update for INSTALLED builds (macOS /Applications bundle,
/// Windows Inno install). The Dart side orchestrates: resolve the release's
/// assets -> download to a staging dir -> hand off to the native
/// `glimpr/update` channel, which verifies and applies (macOS: codesign chain
/// + Team ID, atomic bundle swap; Windows: Ed25519 signature, silent
/// installer). Anything unsupported or failed falls back to the release page
/// (the caller's job). Prereleases (rc) never reach here: the check reads
/// `releases/latest`, which excludes them.
enum UpdatePhase { idle, downloading, installing, failed }

/// name -> browser_download_url for one release tag.
typedef ReleaseAssets = Map<String, String>;

const kUpdateChannel = MethodChannel('glimpr/update');

// Mount/verify/swap (mac) or verify/spawn (win) runs seconds; a hung native
// side must not wedge the flow in "installing" forever.
const _kApplyTimeout = Duration(minutes: 2);

/// Asset names carry the release version since v1.1.1
/// (Glimpr-Setup-1.1.1.exe), so resolution matches by prefix + suffix
/// instead of exact names; pre-1.1.1 unversioned names still match. The
/// .sig is looked up by the matched exe's own name.
MapEntry<String, String>? _findAsset(ReleaseAssets assets, String suffix) {
  for (final e in assets.entries) {
    if (e.key.startsWith('Glimpr') && e.key.endsWith(suffix)) return e;
  }
  return null;
}

class UpdaterService {
  UpdaterService({
    required this.fetchAssets,
    required this.download,
    required this.stageDir,
    this.channel = kUpdateChannel,
  });

  /// Release assets for [tag], or null when the listing is unavailable.
  final Future<ReleaseAssets?> Function(String tag) fetchAssets;

  /// Fetch [url] into [toPath]; throws on any failure.
  final Future<void> Function(String url, String toPath) download;

  /// A fresh writable staging directory per install attempt.
  final Future<Directory> Function() stageDir;

  final MethodChannel channel;

  final ValueNotifier<UpdatePhase> phase = ValueNotifier(UpdatePhase.idle);

  /// Whether THIS running copy can self-update (native check: install
  /// location + writability). False on any error so callers fall back to the
  /// release page.
  Future<bool> supported() async {
    try {
      // Timeout: an engine without the channel never replies (it would hang
      // the caller forever); absent/slow native = unsupported.
      return await channel
              .invokeMethod<bool>('updateSupported')
              .timeout(const Duration(seconds: 3)) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Download + verify + install [tag]. Returns true when the apply step was
  /// handed to native (the process is about to exit/relaunch); false means
  /// nothing was changed and the caller should open the release page instead.
  Future<bool> installTag(String tag) async {
    try {
      phase.value = UpdatePhase.downloading;
      final assets = await fetchAssets(tag);
      if (assets == null) throw StateError('release listing unavailable');
      final dir = await stageDir();
      if (platformIsWindows) {
        final exe = _findAsset(assets, '.exe');
        final sigUrl = exe == null ? null : assets['${exe.key}.sig'];
        if (exe == null || sigUrl == null) {
          throw StateError('installer or signature asset missing');
        }
        final exePath = '${dir.path}${Platform.pathSeparator}${exe.key}';
        final sigPath = '$exePath.sig';
        await download(exe.value, exePath);
        await download(sigUrl, sigPath);
        phase.value = UpdatePhase.installing;
        // A declined apply (failed verification, not installed) changed
        // nothing on disk: fall back like any other failure.
        final applied = await channel.invokeMethod(
            'applyStaged',
            {'path': exePath, 'sigPath': sigPath}).timeout(_kApplyTimeout);
        if (applied != true) throw StateError('apply declined');
      } else {
        final dmg = _findAsset(assets, '.dmg');
        if (dmg == null) throw StateError('dmg asset missing');
        final dmgPath = '${dir.path}${Platform.pathSeparator}${dmg.key}';
        await download(dmg.value, dmgPath);
        phase.value = UpdatePhase.installing;
        final applied = await channel
            .invokeMethod('applyStaged', {'path': dmgPath}).timeout(
                _kApplyTimeout);
        if (applied != true) throw StateError('apply declined');
      }
      return true;
    } catch (_) {
      phase.value = UpdatePhase.failed;
      return false;
    }
  }
}

/// Production asset fetcher: the release-by-tag endpoint (stable releases
/// only ever reach the updater; see the class doc).
Future<ReleaseAssets?> defaultFetchAssets(String tag) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.getUrl(Uri.parse(
        'https://api.github.com/repos/howar31/glimpr/releases/tags/$tag'));
    req.headers.set(HttpHeaders.userAgentHeader, 'Glimpr');
    req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    final res = await req.close().timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;
    final body = await res.transform(utf8.decoder).join();
    return parseReleaseAssets(body);
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// Pure JSON -> asset map (unit-tested; null on malformed input).
ReleaseAssets? parseReleaseAssets(String body) {
  try {
    final json = jsonDecode(body);
    if (json is! Map) return null;
    final assets = json['assets'];
    if (assets is! List) return null;
    final out = <String, String>{};
    for (final a in assets) {
      if (a is! Map) continue;
      final name = a['name'];
      final url = a['browser_download_url'];
      if (name is String && url is String) out[name] = url;
    }
    return out;
  } catch (_) {
    return null;
  }
}

/// Production downloader: one streamed GET to [toPath]; throws on non-200.
Future<void> defaultDownload(String url, String toPath) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.userAgentHeader, 'Glimpr');
    final res = await req.close();
    if (res.statusCode != 200) {
      throw HttpException('HTTP ${res.statusCode} for $url');
    }
    final sink = File(toPath).openWrite();
    await res.pipe(sink);
  } finally {
    client.close(force: true);
  }
}
