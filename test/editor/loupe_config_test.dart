import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/loupe_config.dart';

void main() {
  test('defaults are span 13 / zoom 8, box 104', () {
    const c = LoupeConfig();
    expect(c.span, 13);
    expect(c.zoom, 8);
    expect(c.box, 104.0);
  });

  test('box is span * zoom', () {
    expect(const LoupeConfig(span: 21, zoom: 16).box, 336.0);
    expect(const LoupeConfig(span: 5, zoom: 4).box, 20.0);
  });

  test('clampLoupeSpan clamps to [5, 21] and snaps even values up to odd', () {
    expect(clampLoupeSpan(0), kLoupeSpanMin);
    expect(clampLoupeSpan(99), kLoupeSpanMax);
    expect(clampLoupeSpan(12), 13);
    expect(clampLoupeSpan(13), 13);
    expect(clampLoupeSpan(20), 21);
    expect(clampLoupeSpan(5), 5);
  });

  test('clamped clamps span to [5, 21], odd only', () {
    expect(LoupeConfig.clamped(span: 0, zoom: 8).span, kLoupeSpanMin);
    expect(LoupeConfig.clamped(span: 99, zoom: 8).span, kLoupeSpanMax);
    expect(LoupeConfig.clamped(span: 12, zoom: 8).span, 13);
    expect(LoupeConfig.clamped(span: 11, zoom: 8).span, 11);
  });

  test('clamped clamps zoom to [4, 16]', () {
    expect(LoupeConfig.clamped(span: 13, zoom: 1).zoom, kLoupeZoomMin);
    expect(LoupeConfig.clamped(span: 13, zoom: 99).zoom, kLoupeZoomMax);
    expect(LoupeConfig.clamped(span: 13, zoom: 8).zoom, 8);
  });

  test('clamped uses defaults for null inputs', () {
    final c = LoupeConfig.clamped();
    expect(c.span, kLoupeSpanDefault);
    expect(c.zoom, kLoupeZoomDefault);
  });

  test('value equality', () {
    expect(const LoupeConfig(span: 11, zoom: 6),
        const LoupeConfig(span: 11, zoom: 6));
    expect(const LoupeConfig(span: 11, zoom: 6),
        isNot(const LoupeConfig(span: 13, zoom: 6)));
  });
}
