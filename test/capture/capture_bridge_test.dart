import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/capture/capture_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('glimpr/capture');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('captureFrames parses the native list into CapturedDisplay', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'captureFrames');
      return [
        {
          'displayId': 1,
          'rawBytes': Uint8List(0),
          'pixelWidth': 0,
          'pixelHeight': 0,
          'rowBytes': 0,
          'left': 0.0,
          'top': 0.0,
          'width': 1920.0,
          'height': 1080.0,
          'scaleFactor': 2.0,
          'isCursorDisplay': true,
          'windows': <dynamic>[],
        }
      ];
    });
    final frames = await CaptureBridge().captureFrames();
    expect(frames, hasLength(1));
    expect(frames.first.displayId, 1);
    expect(frames.first.isCursorDisplay, isTrue);
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
