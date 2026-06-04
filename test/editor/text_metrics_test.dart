import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/draw_style.dart';
import 'package:glimpr/editor/text_metrics.dart';

void main() {
  test('textStyleOf carries the font family', () {
    const s = DrawStyle(fontFamily: 'PingFang TC', fontSize: 20);
    final ts = textStyleOf(s);
    expect(ts.fontFamily, 'PingFang TC');
    expect(ts.fontSize, 20);
  });

  test('null family => null fontFamily (system default)', () {
    expect(textStyleOf(const DrawStyle()).fontFamily, isNull);
  });
}
