import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/font_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('glimpr/fonts');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'availableFamilies') {
        return <String>['Helvetica Neue', 'PingFang TC', 'Menlo'];
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('availableFamilies returns the native list', () async {
    final b = FontBridge();
    expect(await b.availableFamilies(), [
      'Helvetica Neue',
      'PingFang TC',
      'Menlo',
    ]);
  });

  test('result is cached after first fetch', () async {
    final b = FontBridge();
    final first = await b.availableFamilies();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => <String>['X']);
    expect(await b.availableFamilies(), first);
  });

  test('a channel error yields an empty list (no throw)', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'boom');
    });
    expect(await FontBridge().availableFamilies(), isEmpty);
  });
}
