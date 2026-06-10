import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/capture/capture_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('glimpr/capture');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('captureRegion parses the native map; null stays null (display gone)',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'captureRegion');
      final args = (call.arguments as Map).cast<dynamic, dynamic>();
      expect(args['displayId'], 7);
      expect(args['x'], 1.0);
      expect(args['jpeg'], false);
      return {
        'bytes': Uint8List.fromList([1, 2]),
        'displayId': 7,
        'x': 1.0, 'y': 2.0, 'w': 30.0, 'h': 40.0,
        'left': 100.0, 'top': 50.0,
        'scaleFactor': 2.0,
      };
    });
    final rc = await CaptureBridge().captureRegion(
        displayId: 7, rect: const Rect.fromLTWH(1, 2, 30, 40));
    expect(rc!.displayId, 7);
    expect(rc.bytes, hasLength(2));
    expect(rc.rect, const Rect.fromLTWH(1, 2, 30, 40));
    expect(rc.displayOrigin, const Offset(100, 50));
    expect(rc.scaleFactor, 2.0);

    messenger.setMockMethodCallHandler(channel, (call) async => null);
    expect(await CaptureBridge().captureRegion(displayId: 9), isNull);
  });

  test('focusedWindow parses a dict, and null stays null', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => {
          'displayId': 2,
          'x': 10.0,
          'y': 20.0,
          'w': 300.0,
          'h': 200.0,
          'title': 'Win',
          'app': 'App',
        });
    final w = await CaptureBridge().focusedWindow();
    expect(w!.displayId, 2);
    expect(w.rect.width, 300);
    expect(w.title, 'Win');

    messenger.setMockMethodCallHandler(channel, (call) async => null);
    expect(await CaptureBridge().focusedWindow(), isNull);
  });
}
