import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/loupe_config.dart';

void main() {
  test('defaults are span 12 / zoom 8, box 96', () {
    const c = LoupeConfig();
    expect(c.span, 12);
    expect(c.zoom, 8);
    expect(c.box, 96.0);
  });

  test('box is span * zoom', () {
    expect(const LoupeConfig(span: 20, zoom: 16).box, 320.0);
    expect(const LoupeConfig(span: 5, zoom: 4).box, 20.0);
  });

  test('clamped clamps span to [5, 20]', () {
    expect(LoupeConfig.clamped(span: 0, zoom: 8).span, kLoupeSpanMin);
    expect(LoupeConfig.clamped(span: 99, zoom: 8).span, kLoupeSpanMax);
    expect(LoupeConfig.clamped(span: 12, zoom: 8).span, 12);
  });

  test('clamped clamps zoom to [4, 16]', () {
    expect(LoupeConfig.clamped(span: 12, zoom: 1).zoom, kLoupeZoomMin);
    expect(LoupeConfig.clamped(span: 12, zoom: 99).zoom, kLoupeZoomMax);
    expect(LoupeConfig.clamped(span: 12, zoom: 8).zoom, 8);
  });

  test('clamped uses defaults for null inputs', () {
    final c = LoupeConfig.clamped();
    expect(c.span, kLoupeSpanDefault);
    expect(c.zoom, kLoupeZoomDefault);
  });

  test('value equality', () {
    expect(const LoupeConfig(span: 10, zoom: 6),
        const LoupeConfig(span: 10, zoom: 6));
    expect(const LoupeConfig(span: 10, zoom: 6),
        isNot(const LoupeConfig(span: 11, zoom: 6)));
  });
}
