import 'dart:io';

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

  UpdaterService make({
    Map<String, String>? assets,
    List<String>? downloadedUrls,
  }) {
    return UpdaterService(
      fetchAssets: (tag) async => assets,
      download: (url, toPath) async {
        downloadedUrls?.add(url);
        await File(toPath).writeAsString('payload of $url');
      },
      stageDir: () async => stage.createTemp('s'),
    );
  }

  test('windows: downloads the installer and its signature, then applies',
      () async {
    debugPlatformOverride = TargetPlatform.windows;
    final calls = mockMethodChannel(_update, handler: (c) => null);
    final urls = <String>[];
    final s = make(assets: {
      'Glimpr-Setup.exe': 'https://example.test/setup.exe',
      'Glimpr-Setup.exe.sig': 'https://example.test/setup.sig',
      'Glimpr-macOS.dmg': 'https://example.test/mac.dmg',
    }, downloadedUrls: urls);
    final handed = await s.installTag('v9.9.9');
    expect(handed, isTrue);
    expect(urls, containsAll(['https://example.test/setup.exe', 'https://example.test/setup.sig']));
    expect(urls, isNot(contains('https://example.test/mac.dmg')));
    final apply = calls.where((c) => c.method == 'applyStaged').toList();
    expect(apply, hasLength(1));
    final args = (apply.single.arguments as Map).cast<String, Object?>();
    expect(File(args['path']! as String).existsSync(), isTrue);
    expect(File(args['sigPath']! as String).existsSync(), isTrue);
    expect(s.phase.value, UpdatePhase.installing);
  });

  test('windows: a release without the signature asset fails closed',
      () async {
    debugPlatformOverride = TargetPlatform.windows;
    final calls = mockMethodChannel(_update, handler: (c) => null);
    final s = make(assets: {
      'Glimpr-Setup.exe': 'https://example.test/setup.exe',
    });
    expect(await s.installTag('v9.9.9'), isFalse);
    expect(calls.where((c) => c.method == 'applyStaged'), isEmpty);
    expect(s.phase.value, UpdatePhase.failed);
  });

  test('macOS: downloads the DMG only and applies', () async {
    debugPlatformOverride = TargetPlatform.macOS;
    final calls = mockMethodChannel(_update, handler: (c) => null);
    final urls = <String>[];
    final s = make(assets: {
      'Glimpr-Setup.exe': 'https://example.test/setup.exe',
      'Glimpr-macOS.dmg': 'https://example.test/mac.dmg',
    }, downloadedUrls: urls);
    expect(await s.installTag('v9.9.9'), isTrue);
    expect(urls, ['https://example.test/mac.dmg']);
    final args =
        (calls.singleWhere((c) => c.method == 'applyStaged').arguments as Map)
            .cast<String, Object?>();
    expect(args.containsKey('sigPath'), isFalse);
  });

  test('a failed download reports failure and never applies', () async {
    debugPlatformOverride = TargetPlatform.macOS;
    final calls = mockMethodChannel(_update, handler: (c) => null);
    final s = UpdaterService(
      fetchAssets: (tag) async => {'Glimpr-macOS.dmg': 'https://x/d.dmg'},
      download: (url, toPath) async => throw const SocketException('offline'),
      stageDir: () async => stage.createTemp('s'),
    );
    expect(await s.installTag('v9.9.9'), isFalse);
    expect(calls.where((c) => c.method == 'applyStaged'), isEmpty);
    expect(s.phase.value, UpdatePhase.failed);
  });

  test('an unavailable release listing fails closed', () async {
    debugPlatformOverride = TargetPlatform.macOS;
    mockMethodChannel(_update, handler: (c) => null);
    final s = make(assets: null);
    expect(await s.installTag('v9.9.9'), isFalse);
    expect(s.phase.value, UpdatePhase.failed);
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
}
