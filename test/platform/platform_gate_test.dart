import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glimpr/channels.dart';
import 'package:glimpr/image_editor/thumb_cache.dart';
import 'package:glimpr/output/deliver.dart';
import 'package:glimpr/output/flow.dart';
import 'package:glimpr/platform_gate.dart';
import 'package:glimpr/theme/glimpr_theme.dart';
import '../support/mock_channels.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => debugPlatformOverride = null);

  test('the gate follows the host until overridden', () {
    expect(platformIsWindows, Platform.isWindows);
    expect(platformIsMacOS, Platform.isMacOS);

    debugPlatformOverride = TargetPlatform.windows;
    expect(platformIsWindows, isTrue);
    expect(platformIsMacOS, isFalse);

    debugPlatformOverride = TargetPlatform.macOS;
    expect(platformIsWindows, isFalse);
    expect(platformIsMacOS, isTrue);
  });

  test('effectiveSaveDir picks the Windows profile variable', () {
    debugPlatformOverride = TargetPlatform.windows;
    final dir = effectiveSaveDir(null);
    // USERPROFILE is unset on a mac host -> HOME fallback; the tail is the
    // same Pictures/Glimpr landing both ways.
    expect(dir.path.endsWith('Pictures${Platform.pathSeparator}Glimpr'),
        isTrue);

    final configured = Directory('/tmp/custom');
    expect(effectiveSaveDir(configured), configured);
  });

  test('titleBarInset is the small Windows inset vs the mac title overlay',
      () {
    debugPlatformOverride = TargetPlatform.windows;
    expect(GlimprTokens.titleBarInset, 16.0);
    debugPlatformOverride = TargetPlatform.macOS;
    expect(GlimprTokens.titleBarInset, 52.0);
  });

  test('ThumbCache default dir lands in LOCALAPPDATA (or temp) on Windows',
      () {
    debugPlatformOverride = TargetPlatform.windows;
    final winDir = ThumbCache().dir.path;
    expect(winDir.contains('com.howar31.glimpr'), isTrue);
    expect(winDir.contains('Library/Caches'), isFalse);

    debugPlatformOverride = TargetPlatform.macOS;
    final macDir = ThumbCache().dir.path;
    expect(macDir.contains('Library'), isTrue);
    expect(macDir.endsWith('thumbs'), isTrue);
  });

  test('runFlow guards the shareSheet leg off on Windows', () async {
    debugPlatformOverride = TargetPlatform.windows;
    var shared = 0;
    final result = await runFlow(
      actions: {FlowAction.shareSheet},
      bytes: Uint8List.fromList([1, 2, 3]),
      shareFn: (_) async => shared++,
      soundFn: () async {},
      writeTempFn: (_) async => '/tmp/fake.png',
    );
    expect(shared, 0);
    expect(result.errors, isEmpty);
  });

  test('runFlow runs the shareSheet leg on macOS', () async {
    debugPlatformOverride = TargetPlatform.macOS;
    var shared = 0;
    await runFlow(
      actions: {FlowAction.shareSheet},
      bytes: Uint8List.fromList([1, 2, 3]),
      shareFn: (_) async => shared++,
      soundFn: () async {},
      writeTempFn: (_) async => '/tmp/fake.png',
    );
    expect(shared, 1);
  });

  test('revealInFileManager routes to the native Shell API on Windows',
      () async {
    debugPlatformOverride = TargetPlatform.windows;
    final calls = mockMethodChannel(kRoleChannel);
    await revealInFileManager('/tmp/a b.png');
    expect(calls.single.method, 'revealInExplorer');
    expect((calls.single.arguments as Map)['path'], '/tmp/a b.png');
  });
}
