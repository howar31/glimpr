import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/capture/capture_bridge.dart';
import 'package:glimpr/capture/captured_display.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const capture = MethodChannel('glimpr/capture');
  const overlay = MethodChannel('glimpr/overlay');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Map<String, Object> displayMap() => {
    'displayId': 1,
    'pngBytes': Uint8List.fromList([1, 2, 3]),
    'left': 0.0,
    'top': 0.0,
    'width': 1512.0,
    'height': 982.0,
    'scaleFactor': 2.0,
    'isCursorDisplay': true,
  };

  test(
    'beginCapture / dismissOverlay / overlayReady invoke the capture channel',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(capture, (call) async {
        calls.add(call.method);
        return null;
      });
      final bridge = CaptureBridge();
      await bridge.beginCapture();
      await bridge.dismissOverlay();
      await bridge.overlayReady();
      expect(calls, ['beginCapture', 'dismissOverlay', 'overlayReady']);
      messenger.setMockMethodCallHandler(capture, null);
    },
  );

  test(
    'registerOverlayHandlers decodes onCaptureReady and onCaptureFailed',
    () async {
      CapturedDisplay? ready;
      String? failReason;
      final bridge = CaptureBridge();
      bridge.registerOverlayHandlers(
        onCaptureReady: (d) => ready = d,
        onCaptureFailed: (reason, msg) => failReason = reason,
      );

      Future<void> send(String method, Object? args) async {
        await messenger.handlePlatformMessage(
          overlay.name,
          overlay.codec.encodeMethodCall(MethodCall(method, args)),
          (_) {},
        );
      }

      await send('onCaptureReady', {'display': displayMap()});
      expect(ready, isNotNull);
      expect(ready!.displayId, 1);
      expect(ready!.scaleFactor, 2.0);

      await send('onCaptureFailed', {
        'reason': 'permissionDenied',
        'message': 'x',
      });
      expect(failReason, 'permissionDenied');
    },
  );
}
