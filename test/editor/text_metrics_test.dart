import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/drawable.dart';
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

  test('buildTextSpan renders the whole text in the single draw style', () {
    const d = TextDrawable(
      Offset.zero,
      'hi',
      DrawStyle(color: Color(0xFF112233), fontSize: 22, fontFamily: 'Courier'),
    );
    final span = buildTextSpan(d);
    expect(span.text, 'hi');
    expect(span.style!.fontFamily, 'Courier');
    expect(span.style!.fontSize, 22);
    expect(span.style!.color, const Color(0xFF112233));
  });
}
