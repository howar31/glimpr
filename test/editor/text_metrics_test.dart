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

  test('text background padding scales with font size', () {
    expect(textBgPadX(20), 20 * 0.35);
    expect(textBgPadY(20), 20 * 0.18);
  });

  test('textBackgroundRect pads the text rect symmetrically', () {
    const textRect = Rect.fromLTWH(10, 10, 100, 26);
    final bg = textBackgroundRect(textRect, 20);
    expect(bg.left, 10 - 7); // padX = 20*0.35 = 7
    expect(bg.top, 10 - 3.6); // padY = 20*0.18 = 3.6
    expect(bg.right, 110 + 7);
    expect(bg.bottom, 36 + 3.6);
  });

  test('textBackgroundRadius is font-scaled and capped to half the short side', () {
    // Tall enough rect: radius = fontSize*0.3.
    expect(textBackgroundRadius(const Rect.fromLTWH(0, 0, 100, 40), 20), 6);
    // Thin rect: capped to shortestSide/2.
    expect(textBackgroundRadius(const Rect.fromLTWH(0, 0, 100, 4), 20), 2);
  });

  test('textOutlineWidth is font-scaled and clamped', () {
    expect(textOutlineWidth(50), 50 * 0.12); // 6
    expect(textOutlineWidth(4), 1.0); // clamp floor (4*0.12=0.48 -> 1)
    expect(textOutlineWidth(200), 10.0); // clamp ceiling (200*0.12=24 -> 10)
  });
}
