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

  test('shadow defaults off, round-trips, and tolerates an old blob', () {
    expect(const DrawStyle().shadow, isFalse);
    // copyWith toggles it; equality + round-trip include it.
    final on = const DrawStyle().copyWith(shadow: true);
    expect(on.shadow, isTrue);
    expect(on == const DrawStyle(), isFalse);
    expect(DrawStyle.fromJson(on.toJson()).shadow, isTrue);
    // Default-off styles omit the key (compact JSON); old blobs load as off.
    expect(const DrawStyle().toJson().containsKey('shadow'), isFalse);
    final old = {'color': 0xFFFF3B30, 'strokeWidth': 4.0, 'fontSize': 18.0};
    expect(DrawStyle.fromJson(old).shadow, isFalse);
  });

  test('stroke range constants are sane', () {
    expect(kStrokeMin, lessThan(kStrokeMax));
    expect(kStrokeWidths.every((w) => w >= kStrokeMin && w <= kStrokeMax), isTrue);
  });

  test('line-tool defaults: solid, end head, straight (0 curve points)', () {
    const d = DrawStyle();
    expect(d.lineStyle, LineStyle.solid);
    expect(d.arrowHeads, ArrowHeads.end);
    expect(d.curvePoints, kCurvePointsDefault);
    expect(kCurvePointsDefault, 0);
    expect(kCurvePointsMin, 0);
  });

  test('lineStyle / arrowHeads / curvePoints round-trip through JSON', () {
    const d = DrawStyle(
      lineStyle: LineStyle.dashDot,
      arrowHeads: ArrowHeads.both,
      curvePoints: 3,
    );
    final r = DrawStyle.fromJson(d.toJson());
    expect(r.lineStyle, LineStyle.dashDot);
    expect(r.arrowHeads, ArrowHeads.both);
    expect(r.curvePoints, 3);
  });

  test('defaults are omitted from JSON, and fall back on read', () {
    const d = DrawStyle();
    final j = d.toJson();
    expect(j.containsKey('lineStyle'), isFalse);
    expect(j.containsKey('arrowHeads'), isFalse);
    expect(j.containsKey('curvePoints'), isFalse);
    final r = DrawStyle.fromJson({'color': 0xFFFF0000});
    expect(r.lineStyle, LineStyle.solid);
    expect(r.arrowHeads, ArrowHeads.end);
    expect(r.curvePoints, kCurvePointsDefault);
  });

  test('curvePoints clamps to the 1..5 range on read', () {
    expect(DrawStyle.fromJson({'curvePoints': 99}).curvePoints, kCurvePointsMax);
    expect(DrawStyle.fromJson({'curvePoints': 0}).curvePoints, kCurvePointsMin);
  });

  test('garbage enum names fall back to defaults', () {
    final r = DrawStyle.fromJson({'lineStyle': 'zzz', 'arrowHeads': 'zzz'});
    expect(r.lineStyle, LineStyle.solid);
    expect(r.arrowHeads, ArrowHeads.end);
  });

  test('strength defaults to 12, omitted from JSON, round-trips, clamps', () {
    expect(const DrawStyle().strength, kRasterStrengthDefault);
    expect(const DrawStyle().toJson().containsKey('strength'), isFalse);
    final s = const DrawStyle().copyWith(strength: 24);
    expect(s.toJson()['strength'], 24);
    expect(DrawStyle.fromJson(s.toJson()).strength, 24);
    expect(DrawStyle.fromJson({'strength': 999}).strength, kRasterStrengthMax);
    expect(DrawStyle.fromJson({'strength': 0}).strength, kRasterStrengthMin);
    expect(
      DrawStyle.fromJson({'color': 0xFFFF0000}).strength,
      kRasterStrengthDefault,
    );
  });

  test('equality and copyWith include strength', () {
    const a = DrawStyle();
    expect(a.copyWith(strength: 20) == a, isFalse);
    expect(a.copyWith(strength: 20).strength, 20);
  });

  test('fill defaults transparent, omitted from JSON, round-trips', () {
    expect(const DrawStyle().fillColor, const Color(0x00000000));
    expect(const DrawStyle().toJson().containsKey('fillColor'), isFalse);
    final filled = const DrawStyle().copyWith(fillColor: const Color(0x80FF0000));
    expect(filled.toJson()['fillColor'], 0x80FF0000);
    expect(DrawStyle.fromJson(filled.toJson()).fillColor, const Color(0x80FF0000));
    // Old blobs (no key) load as no fill.
    expect(DrawStyle.fromJson({'color': 0xFFFF0000}).fillColor,
        const Color(0x00000000));
  });

  test('equality and copyWith include fillColor', () {
    const a = DrawStyle();
    expect(a.copyWith(fillColor: const Color(0x4400FF00)) == a, isFalse);
    expect(a.copyWith(fillColor: const Color(0x4400FF00)).fillColor,
        const Color(0x4400FF00));
  });

  test('cornerRadius defaults to auto, omitted from JSON, round-trips', () {
    expect(const DrawStyle().cornerRadius, kCornerRadiusAuto);
    expect(const DrawStyle().toJson().containsKey('cornerRadius'), isFalse);
    final r = const DrawStyle().copyWith(cornerRadius: 16);
    expect(r.toJson()['cornerRadius'], 16);
    expect(DrawStyle.fromJson(r.toJson()).cornerRadius, 16);
    // Old blobs (no key) load as auto.
    expect(DrawStyle.fromJson({'color': 0xFFFF0000}).cornerRadius,
        kCornerRadiusAuto);
  });

  test('equality and copyWith include cornerRadius', () {
    const a = DrawStyle();
    expect(a.copyWith(cornerRadius: 8) == a, isFalse);
    expect(a.copyWith(cornerRadius: 8).cornerRadius, 8);
  });

  test('resolveCornerRadius: auto sentinel uses the legacy auto radius', () {
    // Large rect: shortestSide/4 capped at 12.
    expect(resolveCornerRadius(kCornerRadiusAuto, const Rect.fromLTWH(0, 0, 100, 100)),
        12);
    // Small rect: shortestSide/4 below the cap.
    expect(resolveCornerRadius(kCornerRadiusAuto, const Rect.fromLTWH(0, 0, 20, 20)),
        5);
  });

  test('resolveCornerRadius: explicit value clamps to [0, shortestSide/2]', () {
    const rect = Rect.fromLTWH(0, 0, 100, 100);
    expect(resolveCornerRadius(30, rect), 30);
    expect(resolveCornerRadius(80, rect), 50); // clamp to shortestSide/2
    expect(resolveCornerRadius(0, rect), 0);
  });

  test('outline defaults transparent, omitted from JSON, round-trips', () {
    expect(const DrawStyle().outlineColor, const Color(0x00000000));
    expect(const DrawStyle().toJson().containsKey('outlineColor'), isFalse);
    final o = const DrawStyle().copyWith(outlineColor: const Color(0xFFFFFFFF));
    expect(o.toJson()['outlineColor'], 0xFFFFFFFF);
    expect(DrawStyle.fromJson(o.toJson()).outlineColor, const Color(0xFFFFFFFF));
    // Old blobs (no key) load as no outline.
    expect(DrawStyle.fromJson({'color': 0xFFFF0000}).outlineColor,
        const Color(0x00000000));
  });

  test('equality and copyWith include outlineColor', () {
    const a = DrawStyle();
    expect(a.copyWith(outlineColor: const Color(0xFF000000)) == a, isFalse);
    expect(a.copyWith(outlineColor: const Color(0xFF000000)).outlineColor,
        const Color(0xFF000000));
  });

  test('arrowHeadScale defaults to 1, omitted from JSON, round-trips, clamps', () {
    expect(const DrawStyle().arrowHeadScale, kArrowHeadScaleDefault);
    expect(const DrawStyle().toJson().containsKey('arrowHeadScale'), isFalse);
    final s = const DrawStyle().copyWith(arrowHeadScale: 2);
    expect(s.toJson()['arrowHeadScale'], 2);
    expect(DrawStyle.fromJson(s.toJson()).arrowHeadScale, 2);
    // Out-of-range clamps; missing key falls back to the default.
    expect(DrawStyle.fromJson({'arrowHeadScale': 99}).arrowHeadScale,
        kArrowHeadScaleMax);
    expect(DrawStyle.fromJson({'arrowHeadScale': 0}).arrowHeadScale,
        kArrowHeadScaleMin);
    expect(DrawStyle.fromJson({'color': 0xFFFF0000}).arrowHeadScale,
        kArrowHeadScaleDefault);
  });

  test('equality and copyWith include arrowHeadScale', () {
    const a = DrawStyle();
    expect(a.copyWith(arrowHeadScale: 1.5) == a, isFalse);
    expect(a.copyWith(arrowHeadScale: 1.5).arrowHeadScale, 1.5);
  });
}
