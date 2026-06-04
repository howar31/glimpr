import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/draw_style.dart';

void main() {
  test('default style is red, medium stroke, 18pt, system font', () {
    const d = DrawStyle();
    expect(d.color, const Color(0xFFFF3B30));
    expect(d.strokeWidth, 4); // kStrokeWidths[1] (medium)
    expect(d.fontSize, 18);
    expect(d.fontFamily, isNull);
  });

  test('exposes the 7 swatch presets', () {
    expect(kColorPresets.length, 7);
  });

  test('copyWith overrides only the given fields', () {
    const base = DrawStyle();
    final c = base.copyWith(strokeWidth: 12);
    expect(c.strokeWidth, 12);
    expect(c.color, base.color);
    expect(c.fontSize, base.fontSize);
  });

  test('copyWith sets and preserves fontFamily', () {
    const base = DrawStyle();
    expect(base.fontFamily, isNull);
    final withFont = base.copyWith(fontFamily: 'PingFang TC');
    expect(withFont.fontFamily, 'PingFang TC');
    // copyWith without fontFamily keeps the existing value.
    expect(withFont.copyWith(fontSize: 22).fontFamily, 'PingFang TC');
  });

  test('equality includes fontFamily', () {
    const a = DrawStyle(fontFamily: 'Helvetica');
    const b = DrawStyle(fontFamily: 'Helvetica');
    const c = DrawStyle(fontFamily: 'Menlo');
    expect(a, b);
    expect(a == c, isFalse);
  });

  test('toJson/fromJson round-trips all fields incl. null family', () {
    const s = DrawStyle(
      color: Color(0x8012AB34),
      strokeWidth: 6,
      fontSize: 24,
      fontFamily: 'PingFang TC',
    );
    final back = DrawStyle.fromJson(s.toJson());
    expect(back, s);

    const noFont = DrawStyle(color: Color(0xFFFF0000));
    expect(DrawStyle.fromJson(noFont.toJson()), noFont);
  });

  test('fromJson tolerates a missing fontFamily key (old blob)', () {
    final old = {'color': 0xFFFF3B30, 'strokeWidth': 4.0, 'fontSize': 18.0};
    final s = DrawStyle.fromJson(old);
    expect(s.fontFamily, isNull);
    expect(s.color, const Color(0xFFFF3B30));
    expect(s.strokeWidth, 4);
    expect(s.fontSize, 18);
  });

  test('highlighter texture round-trips and defaults to streaks', () {
    const s = DrawStyle(texture: HighlighterTexture.frayed);
    expect(DrawStyle.fromJson(s.toJson()).texture, HighlighterTexture.frayed);
    // Default + missing-key fallback.
    expect(const DrawStyle().texture, HighlighterTexture.streaks);
    final old = {'color': 0xFFFF3B30, 'strokeWidth': 4.0, 'fontSize': 18.0};
    expect(DrawStyle.fromJson(old).texture, HighlighterTexture.streaks);
    // A garbage texture value falls back, not throws.
    expect(
      DrawStyle.fromJson({...old, 'texture': 'bogus'}).texture,
      HighlighterTexture.streaks,
    );
  });

  test('stroke range constants are sane', () {
    expect(kStrokeMin, lessThan(kStrokeMax));
    expect(kStrokeWidths.every((w) => w >= kStrokeMin && w <= kStrokeMax), isTrue);
  });
}
