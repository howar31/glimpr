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

const _kMacAsset = 'Glimpr-macOS.dmg';
const _kWinAsset = 'Glimpr-Setup.exe';
const _kWinSigAsset = 'Glimpr-Setup.exe.sig';

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
      return await channel.invokeMethod<bool>('updateSupported') ?? false;
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
        final exeUrl = assets[_kWinAsset];
        final sigUrl = assets[_kWinSigAsset];
        if (exeUrl == null || sigUrl == null) {
          throw StateError('installer or signature asset missing');
        }
        final exePath = '${dir.path}${Platform.pathSeparator}$_kWinAsset';
        final sigPath = '${dir.path}${Platform.pathSeparator}$_kWinSigAsset';
        await download(exeUrl, exePath);
        await download(sigUrl, sigPath);
        phase.value = UpdatePhase.installing;
        await channel.invokeMethod(
            'applyStaged', {'path': exePath, 'sigPath': sigPath});
      } else {
        final dmgUrl = assets[_kMacAsset];
        if (dmgUrl == null) throw StateError('dmg asset missing');
        final dmgPath = '${dir.path}${Platform.pathSeparator}$_kMacAsset';
        await download(dmgUrl, dmgPath);
        phase.value = UpdatePhase.installing;
        await channel.invokeMethod('applyStaged', {'path': dmgPath});
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
