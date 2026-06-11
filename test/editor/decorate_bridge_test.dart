import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/decorate_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('glimpr/encode');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('passes pixels + geometry + scale + spec and returns encoded bytes',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'decorate');
      final a = (call.arguments as Map).cast<dynamic, dynamic>();
      expect(a['width'], 2);
      expect(a['height'], 1);
      expect(a['scale'], 2.0);
      expect(a['jpeg'], false);
      expect(a['quality'], 90);
      expect(a['rgba'], hasLength(8));
      expect((a['decoration'] as Map)['margin'], 60.0);
      return Uint8List.fromList([0x89, 0x50]);
    });
    final out = await decorateNative(
      rgba: Uint8List(8),
      width: 2,
      height: 1,
      scale: 2.0,
      spec: const {'margin': 60.0},
      jpeg: false,
      quality: 90,
    );
    expect(out, Uint8List.fromList([0x89, 0x50]));
  });

  test('missing channel -> null (caller falls back to the dart:ui decorator)',
      () async {
    final out = await decorateNative(
      rgba: Uint8List(8),
      width: 2,
      height: 1,
      scale: 1.0,
      spec: const {},
      jpeg: false,
      quality: 90,
    );
    expect(out, isNull);
  });

  test('native failure (null reply) -> null', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    final out = await decorateNative(
      rgba: Uint8List(8),
      width: 2,
      height: 1,
      scale: 1.0,
      spec: const {},
      jpeg: false,
      quality: 90,
    );
    expect(out, isNull);
  });
}
