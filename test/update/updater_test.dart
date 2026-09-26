import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/platform_gate.dart';
import 'package:glimpr/update/updater.dart';

import '../support/mock_channels.dart';

const _update = MethodChannel('glimpr/update');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory stage;
  setUpAll(() async {
    stage = await Directory.systemTemp.createTemp('updater-test');
  });
  tearDownAll(() => stage.delete(recursive: true));
  tearDown(() {
    debugPlatformOverride = null;
  });

  // Plain url maps (no size/digest) never qualify for reuse, so every
  // pre-existing test keeps its download expectations.
  ReleaseAssets? plain(Map<String, String>? m) => m?.map(
      (k, v) => MapEntry(k, AssetInfo(url: v)));

  UpdaterService make({
    Map<String, String>? assets,
    List<String>? downloadedUrls,
    Directory? root,
  }) {
    return UpdaterService(
      fetchAssets: (tag) async => plain(assets),
      download: (url, toPath, onProgress) async {
        downloadedUrls?.add(url);
        onProgress(0, 10);
        onProgress(10, 10);
        await File(toPath).writeAsString('payload of $url');
      },
      stageRoot: () async => root ?? await stage.createTemp('s'),
    );
  }

  test('windows: downloads the installer and its signature, then applies',
      () async {
    debugPlatformOverride = TargetPlatform.windows;
    final calls = mockMethodChannel(_update, handler: (c) => c.method == 'applyStaged' ? true : null);
    final urls = <String>[];
    final s = make(assets: {
      'Glimpr-Setup-9.9.9.exe': 'https://example.test/setup.exe',
      'Glimpr-Setup-9.9.9.exe.sig': 'https://example.test/setup.sig',
      'Glimpr-macOS-9.9.9.dmg': 'https://example.test/mac.dmg',
      'Glimpr-Windows-Portable-9.9.9.zip': 'https://example.test/portable.zip',
    }, downloadedUrls: urls);
    expect(await s.installTag('v9.9.9'), InstallOutcome.handed);
    expect(urls, containsAll(['https://example.test/setup.exe', 'https://example.test/setup.sig']));
    expect(urls, isNot(contains('https://example.test/mac.dmg')));
    expect(urls, isNot(contains('https://example.test/portable.zip')));
    final apply = calls.where((c) => c.method == 'applyStaged').toList();
    expect(apply, hasLength(1));
    final args = (apply.single.arguments as Map).cast<String, Object?>();
    expect(args['path']! as String, endsWith('Glimpr-Setup-9.9.9.exe'));
    expect(File(args['path']! as String).existsSync(), isTrue);
    expect(File(args['sigPath']! as String).existsSync(), isTrue);
    expect(s.phase.value, UpdatePhase.installing);
  });

  test('windows: a release without the signature asset fails closed',
      () async {
    debugPlatformOverride = TargetPlatform.windows;
    final calls = mockMethodChannel(_update, handler: (c) => c.method == 'applyStaged' ? true : null);
    final s = make(assets: {
      'Glimpr-Setup-9.9.9.exe': 'https://example.test/setup.exe',
    });
    expect(await s.installTag('v9.9.9'), InstallOutcome.failed);
    expect(calls.where((c) => c.method == 'applyStaged'), isEmpty);
    expect(s.phase.value, UpdatePhase.failed);
  });

  test('macOS: downloads the DMG only and applies', () async {
    debugPlatformOverride = TargetPlatform.macOS;
    final calls = mockMethodChannel(_update, handler: (c) => c.method == 'applyStaged' ? true : null);
    final urls = <String>[];
    final s = make(assets: {
      'Glimpr-Setup-9.9.9.exe': 'https://example.test/setup.exe',
      'Glimpr-macOS-9.9.9.dmg': 'https://example.test/mac.dmg',
    }, downloadedUrls: urls);
    expect(await s.installTag('v9.9.9'), InstallOutcome.handed);
    expect(urls, ['https://example.test/mac.dmg']);
    final args =
        (calls.singleWhere((c) => c.method == 'applyStaged').arguments as Map)
            .cast<String, Object?>();
    expect(args.containsKey('sigPath'), isFalse);
  });

  test('pre-1.1.1 unversioned asset names still resolve', () async {
    debugPlatformOverride = TargetPlatform.windows;
    mockMethodChannel(_update, handler: (c) => c.method == 'applyStaged' ? true : null);
    final urls = <String>[];
    final s = make(assets: {
      'Glimpr-Setup.exe': 'https://example.test/setup.exe',
      'Glimpr-Setup.exe.sig': 'https://example.test/setup.sig',
      'Glimpr-macOS.dmg': 'https://example.test/mac.dmg',
    }, downloadedUrls: urls);
    expect(await s.installTag('v9.9.9'), InstallOutcome.handed);
    expect(urls, containsAll(['https://example.test/setup.exe', 'https://example.test/setup.sig']));
  });

  test('a failed download reports failure and never applies', () async {
    debugPlatformOverride = TargetPlatform.macOS;
    final calls = mockMethodChannel(_update, handler: (c) => c.method == 'applyStaged' ? true : null);
    final s = UpdaterService(
      fetchAssets: (tag) async =>
          {'Glimpr-macOS.dmg': const AssetInfo(url: 'https://x/d.dmg')},
      download: (url, toPath, _) async =>
          throw const SocketException('offline'),
      stageRoot: () async => stage.createTemp('s'),
    );
    expect(await s.installTag('v9.9.9'), InstallOutcome.failed);
    expect(calls.where((c) => c.method == 'applyStaged'), isEmpty);
    expect(s.phase.value, UpdatePhase.failed);
  });

  test('an unavailable release listing fails closed', () async {
    debugPlatformOverride = TargetPlatform.macOS;
    mockMethodChannel(_update, handler: (c) => c.method == 'applyStaged' ? true : null);
    final s = make(assets: null);
    expect(await s.installTag('v9.9.9'), InstallOutcome.failed);
    expect(s.phase.value, UpdatePhase.failed);
  });

  test('a DECLINED native apply reports failure and drops the staged file',
      () async {
    debugPlatformOverride = TargetPlatform.macOS;
    final calls = mockMethodChannel(_update,
        handler: (c) => c.method == 'applyStaged' ? false : null);
    final root = await stage.createTemp('root');
    final s = make(assets: {'Glimpr-macOS.dmg': 'https://x/d.dmg'}, root: root);
    expect(await s.installTag('v9.9.9'), InstallOutcome.failed);
    expect(s.phase.value, UpdatePhase.failed);
    final path = (calls.single.arguments as Map)['path'] as String;
    expect(File(path).existsSync(), isFalse);
    expect(await s.stagedExists('v9.9.9'), isFalse);
  });

  test('supported() reflects the native answer and defaults to false',
      () async {
    mockMethodChannel(_update,
        handler: (c) => c.method == 'updateSupported' ? true : null);
    expect(await make().supported(), isTrue);
    // No handler at all (e.g. an engine without the channel): stays false.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_update, null);
    expect(await make().supported(), isFalse);
  });

  test('progress mirrors the main asset download and clears before apply',
      () async {
    debugPlatformOverride = TargetPlatform.windows;
    mockMethodChannel(_update,
        handler: (c) => c.method == 'applyStaged' ? true : null);
    final seen = <DownloadProgress?>[];
    late UpdaterService s;
    s = UpdaterService(
      fetchAssets: (tag) async => {
        'Glimpr-Setup-9.9.9.exe': const AssetInfo(url: 'https://x/setup.exe'),
        'Glimpr-Setup-9.9.9.exe.sig':
            const AssetInfo(url: 'https://x/setup.sig'),
      },
      download: (url, toPath, onProgress) async {
        if (url.endsWith('.exe')) {
          onProgress(0, 100);
          onProgress(40, 100);
          onProgress(100, 100);
        } else {
          // The .sig companion must not disturb the reported progress.
          onProgress(0, 64);
          onProgress(64, 64);
        }
        await File(toPath).writeAsString('x');
      },
      stageRoot: () async => stage.createTemp('s'),
    );
    s.progress.addListener(() => seen.add(s.progress.value));
    expect(await s.installTag('v9.9.9'), InstallOutcome.handed);
    final fractions = seen.map((p) => p?.fraction).toList();
    expect(fractions, [0.0, 0.4, 1.0, null]);
    expect(s.progress.value, isNull);
  });

  String digestOf(String payload) =>
      'sha256:${sha256.convert(utf8.encode(payload))}';

  UpdaterService withDigests(Directory root, List<String> urls,
      {required String exeDigest, int? exeSize}) {
    const payload = 'payload of https://x/setup.exe';
    return UpdaterService(
      fetchAssets: (tag) async => {
        'Glimpr-Setup-9.9.9.exe': AssetInfo(
            url: 'https://x/setup.exe',
            size: exeSize ?? payload.length,
            digest: exeDigest),
        'Glimpr-Setup-9.9.9.exe.sig':
            const AssetInfo(url: 'https://x/setup.sig', size: 64),
      },
      download: (url, toPath, onProgress) async {
        urls.add(url);
        await File(toPath).writeAsString('payload of $url');
      },
      stageRoot: () async => root,
    );
  }

  test('stages under <root>/<tag> and reuses a staged file whose size and '
      'digest match the listing (the .sig is still fetched fresh)', () async {
    debugPlatformOverride = TargetPlatform.windows;
    mockMethodChannel(_update,
        handler: (c) => c.method == 'applyStaged' ? true : null);
    final root = await stage.createTemp('root');
    const payload = 'payload of https://x/setup.exe';
    final urls = <String>[];
    final s = withDigests(root, urls, exeDigest: digestOf(payload));
    expect(await s.installTag('v9.9.9'), InstallOutcome.handed);
    expect(urls, ['https://x/setup.exe', 'https://x/setup.sig']);
    final exe = File('${root.path}/v9.9.9/Glimpr-Setup-9.9.9.exe');
    expect(exe.existsSync(), isTrue);
    expect(await s.stagedExists('v9.9.9'), isTrue);

    // Second attempt (e.g. after a declined UAC): the installer is NOT
    // downloaded again, the signature is.
    urls.clear();
    expect(await s.installTag('v9.9.9'), InstallOutcome.handed);
    expect(urls, ['https://x/setup.sig']);
  });

  test('a staged file whose digest differs from the listing is replaced',
      () async {
    debugPlatformOverride = TargetPlatform.windows;
    mockMethodChannel(_update,
        handler: (c) => c.method == 'applyStaged' ? true : null);
    final root = await stage.createTemp('root');
    final exe = File('${root.path}/v9.9.9/Glimpr-Setup-9.9.9.exe')
      ..createSync(recursive: true)
      // Same length as the genuine payload, one byte different.
      ..writeAsStringSync('Payload of https://x/setup.exe');
    expect(exe.lengthSync(), 'payload of https://x/setup.exe'.length);
    final urls = <String>[];
    final s = withDigests(root, urls,
        exeDigest: digestOf('payload of https://x/setup.exe'));
    expect(await s.installTag('v9.9.9'), InstallOutcome.handed);
    expect(urls, contains('https://x/setup.exe'));
    expect(exe.readAsStringSync(), 'payload of https://x/setup.exe');
  });

  test('a listing without a digest never reuses a staged file', () async {
    debugPlatformOverride = TargetPlatform.windows;
    mockMethodChannel(_update,
        handler: (c) => c.method == 'applyStaged' ? true : null);
    final root = await stage.createTemp('root');
    final urls = <String>[];
    final s = make(assets: {
      'Glimpr-Setup-9.9.9.exe': 'https://x/setup.exe',
      'Glimpr-Setup-9.9.9.exe.sig': 'https://x/setup.sig',
    }, downloadedUrls: urls, root: root);
    expect(await s.installTag('v9.9.9'), InstallOutcome.handed);
    urls.clear();
    expect(await s.installTag('v9.9.9'), InstallOutcome.handed);
    expect(urls, contains('https://x/setup.exe'));
  });

  test('an interrupted download never counts as staged; the retry starts over',
      () async {
    debugPlatformOverride = TargetPlatform.windows;
    mockMethodChannel(_update,
        handler: (c) => c.method == 'applyStaged' ? true : null);
    final root = await stage.createTemp('root');
    var attempts = 0;
    final s = UpdaterService(
      fetchAssets: (tag) async => {
        'Glimpr-Setup-9.9.9.exe': const AssetInfo(url: 'https://x/setup.exe'),
        'Glimpr-Setup-9.9.9.exe.sig':
            const AssetInfo(url: 'https://x/setup.sig'),
      },
      download: (url, toPath, onProgress) async {
        if (url.endsWith('.exe') && ++attempts == 1) {
          // Half the bytes, then the connection drops.
          await File(toPath).writeAsString('half');
          throw const SocketException('dropped');
        }
        await File(toPath).writeAsString('payload of $url');
      },
      stageRoot: () async => root,
    );
    expect(await s.installTag('v9.9.9'), InstallOutcome.failed);
    // Only the .part is on disk: the final name is absent, so the About row
    // will NOT claim a download is ready.
    final dir = Directory('${root.path}/v9.9.9');
    expect(File('${dir.path}/Glimpr-Setup-9.9.9.exe').existsSync(), isFalse);
    expect(File('${dir.path}/Glimpr-Setup-9.9.9.exe.part').existsSync(),
        isTrue);
    expect(await s.stagedExists('v9.9.9'), isFalse);

    // Launch-time cleanup keeps the pending tag but drops the fragment.
    await s.cleanupStaging(keepTag: 'v9.9.9');
    expect(dir.existsSync(), isTrue);
    expect(File('${dir.path}/Glimpr-Setup-9.9.9.exe.part').existsSync(),
        isFalse);

    // The retry downloads afresh and lands the final name.
    expect(await s.installTag('v9.9.9'), InstallOutcome.handed);
    expect(File('${dir.path}/Glimpr-Setup-9.9.9.exe').readAsStringSync(),
        'payload of https://x/setup.exe');
    expect(await s.stagedExists('v9.9.9'), isTrue);
  });

  test('verifiedAgainst checks existence, length and sha256', () async {
    final dir = await stage.createTemp('v');
    final f = File('${dir.path}/a.bin')..writeAsStringSync('abc');
    final good = AssetInfo(url: 'u', size: 3, digest: digestOf('abc'));
    expect(await UpdaterService.verifiedAgainst(f, good), isTrue);
    expect(
        await UpdaterService.verifiedAgainst(
            f, AssetInfo(url: 'u', size: 4, digest: digestOf('abc'))),
        isFalse);
    expect(
        await UpdaterService.verifiedAgainst(
            f, AssetInfo(url: 'u', size: 3, digest: digestOf('abd'))),
        isFalse);
    expect(await UpdaterService.verifiedAgainst(f, const AssetInfo(url: 'u')),
        isFalse);
    expect(
        await UpdaterService.verifiedAgainst(
            File('${dir.path}/missing'), good),
        isFalse);
  });

  test('cleanupStaging keeps only the pending tag and drops legacy folders',
      () async {
    final root = await stage.createTemp('root');
    final legacy = await stage.createTemp('legacy');
    for (final t in ['v1.0.0', 'v1.1.0', 'v1.2.0']) {
      File('${root.path}/$t/Glimpr-Setup-$t.exe')
        ..createSync(recursive: true)
        ..writeAsStringSync('x');
    }
    Directory('${legacy.path}/glimpr-update1234').createSync();
    Directory('${legacy.path}/other').createSync();
    final s = UpdaterService(
      fetchAssets: (_) async => null,
      download: (_, _, _) async {},
      stageRoot: () async => root,
      legacyTemp: legacy,
    );
    await s.cleanupStaging(keepTag: 'v1.2.0');
    expect(Directory('${root.path}/v1.2.0').existsSync(), isTrue);
    expect(Directory('${root.path}/v1.1.0').existsSync(), isFalse);
    expect(Directory('${root.path}/v1.0.0').existsSync(), isFalse);
    expect(Directory('${legacy.path}/glimpr-update1234').existsSync(), isFalse);
    expect(Directory('${legacy.path}/other').existsSync(), isTrue);
    await s.cleanupStaging();
    expect(Directory('${root.path}/v1.2.0').existsSync(), isFalse);
  });

  test('parseReleaseAssets keeps size and digest', () {
    final assets = parseReleaseAssets(jsonEncode({
      'assets': [
        {
          'name': 'Glimpr-Setup-1.0.0.exe',
          'browser_download_url': 'https://x/s.exe',
          'size': 42,
          'digest': 'sha256:abc',
        },
        {'name': 'old.exe', 'browser_download_url': 'https://x/o.exe'},
      ]
    }))!;
    expect(assets['Glimpr-Setup-1.0.0.exe']!.size, 42);
    expect(assets['Glimpr-Setup-1.0.0.exe']!.digest, 'sha256:abc');
    expect(assets['old.exe']!.size, isNull);
    expect(assets['old.exe']!.digest, isNull);
  });

  test('windows: a declined elevation prompt is cancelled, not failed, and '
      'keeps the staged file', () async {
    debugPlatformOverride = TargetPlatform.windows;
    mockMethodChannel(_update,
        handler: (c) => c.method == 'applyStaged' ? 'cancelled' : null);
    final root = await stage.createTemp('root');
    final s = make(assets: {
      'Glimpr-Setup-9.9.9.exe': 'https://x/setup.exe',
      'Glimpr-Setup-9.9.9.exe.sig': 'https://x/setup.sig',
    }, root: root);
    expect(await s.installTag('v9.9.9'), InstallOutcome.cancelled);
    expect(s.phase.value, UpdatePhase.idle);
    expect(s.progress.value, isNull);
    expect(await s.stagedExists('v9.9.9'), isTrue);
  });

  test('DownloadProgress.fraction is null without a total', () {
    expect(const DownloadProgress(5, null).fraction, isNull);
    expect(const DownloadProgress(5, 0).fraction, isNull);
    expect(const DownloadProgress(5, 10).fraction, 0.5);
    expect(const DownloadProgress(20, 10).fraction, 1.0);
  });
}
