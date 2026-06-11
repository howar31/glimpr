import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/output/clipboard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('glimpr/clipboard');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('writeImage sends the encoded bytes', () async {
    Uint8List? sent;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'writeImage');
      sent = (call.arguments as Map)['bytes'] as Uint8List;
      return null;
    });
    await clipboardWriteImage(Uint8List.fromList([1, 2, 3]));
    expect(sent, Uint8List.fromList([1, 2, 3]));
  });

  test('writeImage propagates a native failure', () async {
    messenger.setMockMethodCallHandler(
        channel, (call) async => throw PlatformException(code: 'clipboard_write'));
    expect(() => clipboardWriteImage(Uint8List(1)),
        throwsA(isA<PlatformException>()));
  });

  test('readImage returns the PNG bytes; null stays null', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'readImage');
      return Uint8List.fromList([9, 9]);
    });
    expect(await clipboardReadImage(), Uint8List.fromList([9, 9]));

    messenger.setMockMethodCallHandler(channel, (call) async => null);
    expect(await clipboardReadImage(), isNull);
  });
}
