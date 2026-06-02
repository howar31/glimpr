import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/capture/captured_display.dart';

Map<String, dynamic> _base() => {
      'displayId': 1,
      'pngBytes': Uint8List(0),
      'left': 0.0,
      'top': 0.0,
      'width': 800.0,
      'height': 600.0,
      'scaleFactor': 2.0,
      'isCursorDisplay': true,
    };

void main() {
  test('decodes the windows rect list (empty when absent)', () {
    expect(CapturedDisplay.fromMap(_base()).windows, isEmpty);

    final m = _base()
      ..['windows'] = [
        [10.0, 20.0, 100.0, 50.0],
        [0.0, 0.0, 800.0, 600.0],
      ];
    final d = CapturedDisplay.fromMap(m);
    expect(d.windows, const [
      Rect.fromLTWH(10, 20, 100, 50),
      Rect.fromLTWH(0, 0, 800, 600),
    ]);
  });
}
