import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/capture/captured_display.dart';

Map<String, dynamic> _base() => {
  'displayId': 1,
  'rawBytes': Uint8List(16),
  'pixelWidth': 2,
  'pixelHeight': 2,
  'rowBytes': 8,
  'left': 0.0,
  'top': 0.0,
  'width': 800.0,
  'height': 600.0,
  'scaleFactor': 2.0,
  'isCursorDisplay': true,
};

void main() {
  test('parses the raw-pixel fields', () {
    final d = CapturedDisplay.fromMap(_base());
    expect(d.rawBytes.length, 16);
    expect(d.pixelWidth, 2);
    expect(d.pixelHeight, 2);
    expect(d.rowBytes, 8);
  });

  test('decodes the windows list (empty when absent)', () {
    expect(CapturedDisplay.fromMap(_base()).windows, isEmpty);

    final m = _base()
      ..['windows'] = [
        {'x': 10.0, 'y': 20.0, 'w': 100.0, 'h': 50.0, 'title': 'Doc', 'app': 'Pages'},
        {'x': 0.0, 'y': 0.0, 'w': 800.0, 'h': 600.0, 'title': '', 'app': 'Finder'},
      ];
    final d = CapturedDisplay.fromMap(m);
    expect(d.windows.length, 2);
    expect(d.windows[0].rect, const Rect.fromLTWH(10, 20, 100, 50));
    expect(d.windows[0].title, 'Doc');
    expect(d.windows[0].app, 'Pages');
    expect(d.windows[0].label, 'Doc'); // title preferred
    expect(d.windows[1].rect, const Rect.fromLTWH(0, 0, 800, 600));
    expect(d.windows[1].label, 'Finder'); // empty title -> app name
  });

  test('withoutPixels drops the raw frame and detaches the cursor bytes', () {
    final buffer = Uint8List(64);
    final d = CapturedDisplay.fromMap({
      ..._base(),
      'rawBytes': Uint8List.view(buffer.buffer, 0, 16),
      'cursorImage': Uint8List.view(buffer.buffer, 16, 8),
      'cursorLeft': 3.0,
      'cursorTop': 4.0,
      'hdrGen': 7,
    });
    expect(d.hasPixels, isTrue);
    final g = d.withoutPixels();
    expect(g.hasPixels, isFalse);
    expect(g.rawBytes, isEmpty);
    // The cursor PNG survives as its own copy, not a view on the frame buffer.
    expect(g.cursorImageBytes, hasLength(8));
    expect(identical(g.cursorImageBytes!.buffer, buffer.buffer), isFalse);
    // Geometry and metadata are unchanged.
    expect(g.displayId, d.displayId);
    expect(g.pixelWidth, d.pixelWidth);
    expect(g.pixelHeight, d.pixelHeight);
    expect(g.rowBytes, d.rowBytes);
    expect(g.width, d.width);
    expect(g.height, d.height);
    expect(g.scaleFactor, d.scaleFactor);
    expect(g.isCursorDisplay, d.isCursorDisplay);
    expect(g.cursorLeft, 3.0);
    expect(g.cursorTop, 4.0);
    expect(g.hdrGen, 7);
    expect(g.windows, same(d.windows));
  });
}
