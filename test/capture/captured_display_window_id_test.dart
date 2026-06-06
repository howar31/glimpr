import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/capture/captured_display.dart';

Map<String, Object?> _base(List<Map<String, Object?>> windows) => {
  'displayId': 1,
  'pngBytes': Uint8List(0),
  'left': 0.0,
  'top': 0.0,
  'width': 100.0,
  'height': 100.0,
  'scaleFactor': 2.0,
  'isCursorDisplay': true,
  'windows': windows,
};

void main() {
  test('CapturedDisplay parses a snap window number into windowId', () {
    final d = CapturedDisplay.fromMap(_base([
      {'x': 0.0, 'y': 0.0, 'w': 10.0, 'h': 10.0, 'title': 'T', 'app': 'A',
       'windowNumber': 42},
    ]));
    expect(d.windows.single.windowId, 42);
  });

  test('SnapWindow.windowId is null when absent', () {
    final d = CapturedDisplay.fromMap(_base([
      {'x': 0.0, 'y': 0.0, 'w': 10.0, 'h': 10.0, 'title': 'T', 'app': 'A'},
    ]));
    expect(d.windows.single.windowId, isNull);
  });

  test('FocusedWindowInfo parses windowNumber', () {
    final f = FocusedWindowInfo.fromMap({
      'displayId': 1, 'x': 0.0, 'y': 0.0, 'w': 10.0, 'h': 10.0,
      'title': 'T', 'app': 'A', 'windowNumber': 7,
    });
    expect(f.windowId, 7);
  });

  test('CapturedDisplay parses the cursor image + position (and tolerates absence)',
      () {
    final withCursor = CapturedDisplay.fromMap({
      ..._base(const []),
      'cursorImage': Uint8List.fromList([1, 2, 3]),
      'cursorLeft': 100.5,
      'cursorTop': 200.5,
    });
    expect(withCursor.cursorImageBytes, isNotNull);
    expect(withCursor.cursorLeft, 100.5);
    expect(withCursor.cursorTop, 200.5);

    final without = CapturedDisplay.fromMap(_base(const []));
    expect(without.cursorImageBytes, isNull);
    expect(without.cursorLeft, isNull);
  });

  test('WindowImage.fromMap parses geometry', () {
    final wi = WindowImage.fromMap({
      'pngBytes': Uint8List(0), 'width': 200, 'height': 160, 'scale': 2.0,
    });
    expect(wi.width, 200);
    expect(wi.height, 160);
    expect(wi.scale, 2.0);
  });
}
