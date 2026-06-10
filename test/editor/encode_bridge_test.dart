import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/encode_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('glimpr/encode');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('passes pixels + geometry + quality and returns the encoded bytes',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'jpeg');
      final a = (call.arguments as Map).cast<dynamic, dynamic>();
      expect(a['width'], 2);
      expect(a['height'], 1);
      expect(a['quality'], 80);
      expect(a['rgba'], hasLength(8));
      return Uint8List.fromList([0xFF, 0xD8]);
    });
    final out = await encodeJpegNative(Uint8List(8), 2, 1, 80);
    expect(out, Uint8List.fromList([0xFF, 0xD8]));
  });

  test('missing channel -> null (caller falls back to the Dart encoder)',
      () async {
    expect(await encodeJpegNative(Uint8List(8), 2, 1, 80), isNull);
  });

  test('native failure (null reply) -> null', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    expect(await encodeJpegNative(Uint8List(8), 2, 1, 80), isNull);
  });
}
