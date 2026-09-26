import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
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

/// How [UpdaterService.installTag] ended.
enum InstallOutcome {
  /// The native apply is running; this process is about to exit/relaunch.
  handed,

  /// The user declined the elevation prompt (Windows): nothing changed, the
  /// staged download stays, and the caller shows no error.
  cancelled,

  /// Download, verification or apply failed; the caller falls back to the
  /// release page.
  failed,
}

/// Bytes received so far and the expected total (null when the server sent
/// no Content-Length; the UI then shows an indeterminate bar).
class DownloadProgress {
  const DownloadProgress(this.received, this.total);
  final int received;
  final int? total;

  /// 0..1 when the total is known, else null.
  double? get fraction {
    final t = total;
    if (t == null || t <= 0) return null;
    return (received / t).clamp(0.0, 1.0);
  }
}

/// Progress sink for one download; [total] is null when unknown.
typedef ProgressSink = void Function(int received, int? total);

/// One release asset as the GitHub API lists it. [digest] is the API's
/// `sha256:<hex>` when present (null on older listings); a staged file is
/// reused ONLY when both [size] and [digest] match it, so a file that was
/// tampered with, truncated, or belongs to a re-cut release is re-downloaded.
class AssetInfo {
  const AssetInfo({required this.url, this.size, this.digest});
  final String url;
  final int? size;
  final String? digest;
}

/// name -> asset for one release tag.
typedef ReleaseAssets = Map<String, AssetInfo>;

const kUpdateChannel = MethodChannel('glimpr/update');

// Mount/verify/swap (mac) runs seconds; on Windows the apply also waits on
// the user's answer to the elevation prompt (Windows itself dismisses an
// unanswered prompt after a couple of minutes). A hung native side must not
// wedge the flow in "installing" forever.
const _kApplyTimeout = Duration(minutes: 5);

// A download that stops delivering bytes for this long is dead (captive
// portal, dropped connection): fail it so the flow falls back to the release
// page instead of sitting in "downloading" forever. Measured between chunks,
// so a slow-but-moving link never trips it.
const kDownloadStallTimeout = Duration(seconds: 30);

/// Suffix of an in-flight download; the file takes its final name only once
/// every byte is written.
const kPartialSuffix = '.part';

/// Asset names carry the release version since v1.1.1
/// (Glimpr-Setup-1.1.1.exe), so resolution matches by prefix + suffix
/// instead of exact names; pre-1.1.1 unversioned names still match. The
/// .sig is looked up by the matched exe's own name.
MapEntry<String, AssetInfo>? _findAsset(ReleaseAssets assets, String suffix) {
  for (final e in assets.entries) {
    if (e.key.startsWith('Glimpr') && e.key.endsWith(suffix)) return e;
  }
  return null;
}

class UpdaterService {
  UpdaterService({
    required this.fetchAssets,
    required this.download,
    required this.stageRoot,
    this.legacyTemp,
    this.channel = kUpdateChannel,
  });

  /// Release assets for [tag], or null when the listing is unavailable.
  final Future<ReleaseAssets?> Function(String tag) fetchAssets;

  /// Fetch [url] into [toPath], reporting bytes through [onProgress]; throws
  /// on any failure (including a stalled transfer).
  final Future<void> Function(
      String url, String toPath, ProgressSink onProgress) download;

  /// The staging root; each tag stages under `<root>/<tag>/`, so a download
  /// that was applied but not installed (declined UAC, app quit) is found
  /// again on the next attempt instead of being fetched twice.
  final Future<Directory> Function() stageRoot;

  /// Where releases before the per-tag layout staged (`glimpr-update*`
  /// folders in the system temp dir); [cleanupStaging] removes them.
  final Directory? legacyTemp;

  final MethodChannel channel;

  final ValueNotifier<UpdatePhase> phase = ValueNotifier(UpdatePhase.idle);

  /// Byte progress of the main asset while [phase] is downloading; null
  /// outside that phase. The tiny .sig companion is not tracked.
  final ValueNotifier<DownloadProgress?> progress = ValueNotifier(null);

  void _report(int received, int? total) {
    progress.value = DownloadProgress(received, total);
  }

  static void _ignoreProgress(int received, int? total) {}

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

  /// Download + verify + install [tag]; see [InstallOutcome]. Anything other
  /// than [InstallOutcome.handed] changed nothing on disk except, on
  /// failure, the staged file a refused apply removed.
  Future<InstallOutcome> installTag(String tag) async {
    try {
      progress.value = null;
      phase.value = UpdatePhase.downloading;
      final assets = await fetchAssets(tag);
      if (assets == null) throw StateError('release listing unavailable');
      final dir = await _tagDir(tag);
      if (platformIsWindows) {
        final exe = _findAsset(assets, '.exe');
        final sig = exe == null ? null : assets['${exe.key}.sig'];
        if (exe == null || sig == null) {
          throw StateError('installer or signature asset missing');
        }
        final exePath = '${dir.path}${Platform.pathSeparator}${exe.key}';
        final sigPath = '$exePath.sig';
        await _fetchOrReuse(exe.value, exePath);
        // The signature is always fetched fresh: the staged installer must
        // verify against what GitHub publishes NOW, never a stored copy.
        await download(sig.url, sigPath, _ignoreProgress);
        progress.value = null;
        phase.value = UpdatePhase.installing;
        // A declined apply (failed verification, not installed) changed
        // nothing on disk: fall back like any other failure.
        final applied = await channel.invokeMethod(
            'applyStaged',
            {'path': exePath, 'sigPath': sigPath}).timeout(_kApplyTimeout);
        if (applied == 'cancelled') {
          progress.value = null;
          phase.value = UpdatePhase.idle;
          return InstallOutcome.cancelled;
        }
        if (applied != true) await _discardDeclined(exePath);
      } else {
        final dmg = _findAsset(assets, '.dmg');
        if (dmg == null) throw StateError('dmg asset missing');
        final dmgPath = '${dir.path}${Platform.pathSeparator}${dmg.key}';
        await _fetchOrReuse(dmg.value, dmgPath);
        progress.value = null;
        phase.value = UpdatePhase.installing;
        final applied = await channel
            .invokeMethod('applyStaged', {'path': dmgPath}).timeout(
                _kApplyTimeout);
        if (applied != true) await _discardDeclined(dmgPath);
      }
      return InstallOutcome.handed;
    } catch (_) {
      progress.value = null;
      phase.value = UpdatePhase.failed;
      return InstallOutcome.failed;
    }
  }

  // A file the native side refused (signature / codesign mismatch) must not
  // be offered again: without this, a staged file whose digest matches the
  // listing but whose signature does not would be reused and refused on
  // every tap. Dropping it makes the next attempt download afresh.
  Future<Never> _discardDeclined(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    throw StateError('apply declined');
  }

  Future<Directory> _tagDir(String tag) async {
    final root = await stageRoot();
    return Directory('${root.path}${Platform.pathSeparator}$tag')
        .create(recursive: true);
  }

  // Reuses the file at [path] when it matches the listing's size AND
  // sha256 digest; otherwise deletes whatever is there and downloads. A
  // listing without a digest never qualifies for reuse. The download lands
  // in a `.part` sibling and is renamed only once complete, so a transfer
  // cut short (app quit, crash, dropped link) never leaves a file under the
  // final name: "downloaded" in the UI means the whole file is there.
  Future<void> _fetchOrReuse(AssetInfo asset, String path) async {
    final f = File(path);
    if (await verifiedAgainst(f, asset)) {
      final size = asset.size;
      _report(size ?? 0, size);
      return;
    }
    if (await f.exists()) await f.delete();
    final part = File('$path$kPartialSuffix');
    if (await part.exists()) await part.delete();
    await download(asset.url, part.path, _report);
    await part.rename(path);
  }

  /// Whether [file] is byte-for-byte the asset GitHub lists: it exists, its
  /// length equals [AssetInfo.size], and its SHA-256 equals
  /// [AssetInfo.digest] (`sha256:<hex>`). False when the listing carries no
  /// digest or size, so the answer is never a guess.
  static Future<bool> verifiedAgainst(File file, AssetInfo asset) async {
    final size = asset.size;
    final digest = asset.digest;
    if (size == null || digest == null) return false;
    if (!await file.exists() || await file.length() != size) return false;
    final hex = (await sha256.bind(file.openRead()).first).toString();
    return digest.toLowerCase() == 'sha256:$hex';
  }

  /// Whether a download for [tag] is staged (the platform's main asset is
  /// present under `<root>/<tag>/`). A presence check only; [installTag]
  /// re-verifies it against the release listing before anything runs.
  Future<bool> stagedExists(String tag) async {
    try {
      final root = await stageRoot();
      final dir = Directory('${root.path}${Platform.pathSeparator}$tag');
      if (!await dir.exists()) return false;
      final suffix = platformIsWindows ? '.exe' : '.dmg';
      await for (final e in dir.list()) {
        final name = e.uri.pathSegments.last;
        if (e is File && name.startsWith('Glimpr') && name.endsWith(suffix)) {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  /// Removes every staged tag except [keepTag] (null keeps nothing) and the
  /// legacy `glimpr-update*` folders in [legacyTemp]. Run at launch: after a
  /// successful install the running version is the latest, so everything
  /// goes; after a declined install the pending tag stays for the next tap.
  Future<void> cleanupStaging({String? keepTag}) async {
    try {
      final root = await stageRoot();
      if (await root.exists()) {
        await for (final e in root.list()) {
          if (e is! Directory) continue;
          if (e.uri.pathSegments.where((s) => s.isNotEmpty).last == keepTag) {
            // The pending tag stays, but an interrupted transfer in it is
            // dead weight (the next attempt starts over anyway).
            await for (final f in e.list()) {
              if (f is File && f.path.endsWith(kPartialSuffix)) {
                await f.delete();
              }
            }
            continue;
          }
          await e.delete(recursive: true);
        }
      }
    } catch (_) {}
    final legacy = legacyTemp;
    if (legacy == null) return;
    try {
      await for (final e in legacy.list()) {
        final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (e is Directory && name.startsWith('glimpr-update')) {
          await e.delete(recursive: true);
        }
      }
    } catch (_) {}
  }
}

/// The production staging root: `<system temp>/Glimpr/update`.
Future<Directory> defaultStageRoot() =>
    Directory('${Directory.systemTemp.path}${Platform.pathSeparator}Glimpr'
            '${Platform.pathSeparator}update')
        .create(recursive: true);

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
    final out = <String, AssetInfo>{};
    for (final a in assets) {
      if (a is! Map) continue;
      final name = a['name'];
      final url = a['browser_download_url'];
      final size = a['size'];
      final digest = a['digest'];
      if (name is String && url is String) {
        out[name] = AssetInfo(
            url: url,
            size: size is int ? size : null,
            digest: digest is String && digest.isNotEmpty ? digest : null);
      }
    }
    return out;
  } catch (_) {
    return null;
  }
}

/// Production downloader: one streamed GET to [toPath]; throws on non-200,
/// on a transport error, or when no bytes arrive for [stall]. Progress goes
/// out per chunk with the Content-Length total (null when absent).
Future<void> defaultDownload(String url, String toPath, ProgressSink onProgress,
    {Duration stall = kDownloadStallTimeout}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.userAgentHeader, 'Glimpr');
    final res = await req.close().timeout(stall);
    if (res.statusCode != 200) {
      throw HttpException('HTTP ${res.statusCode} for $url');
    }
    final total = res.contentLength > 0 ? res.contentLength : null;
    var received = 0;
    onProgress(received, total);
    final sink = File(toPath).openWrite();
    try {
      // Stream.timeout fires when the gap BETWEEN chunks exceeds [stall];
      // it does not cap the whole transfer.
      await for (final chunk in res.timeout(stall)) {
        sink.add(chunk);
        received += chunk.length;
        onProgress(received, total);
      }
    } finally {
      await sink.close();
    }
  } finally {
    client.close(force: true);
  }
}
