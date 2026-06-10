import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/draw_style.dart';
import 'package:glimpr/editor/drawable.dart';
import 'package:glimpr/editor/spotlight.dart';

void main() {
  const style = DrawStyle();
  const spot = SpotlightDrawable(Rect.fromLTWH(0, 0, 10, 10), style);
  const rectD = RectangleDrawable(Rect.fromLTWH(0, 0, 5, 5), style);
  const blurD = BlurDrawable(Rect.fromLTWH(0, 0, 5, 5), style);
  const pixD = PixelateDrawable(Rect.fromLTWH(0, 0, 5, 5), style);

  test('spotlightSigma maps feather to mask sigma; 0 stays 0', () {
    expect(spotlightSigma(24), 12);
    expect(spotlightSigma(0), 0);
  });

  test('paintsUnderSpotlight: only raster regions go under the layer', () {
    expect(paintsUnderSpotlight(blurD), isTrue);
    expect(paintsUnderSpotlight(pixD), isTrue);
    expect(paintsUnderSpotlight(rectD), isFalse);
    expect(paintsUnderSpotlight(spot), isFalse);
  });

  test('spotlightLayerStyle: null without spotlights, last spotlight wins', () {
    expect(spotlightLayerStyle([rectD, blurD]), isNull);
    final s2 = SpotlightDrawable(
        const Rect.fromLTWH(1, 1, 2, 2), style.copyWith(spotlightDim: 80));
    expect(spotlightLayerStyle([spot, rectD, s2])!.spotlightDim, 80);
  });

  test('mergeSpotlightLayerFields copies layer fields, keeps per-hole fields',
      () {
    final target = style.copyWith(cornerRadius: 7.0, spotlightDim: 10);
    final source = style.copyWith(
      spotlightDim: 60,
      spotlightEffect: SpotlightEffect.blur,
      spotlightFeather: 8,
      strength: 20,
      cornerRadius: 99.0,
    );
    final merged = mergeSpotlightLayerFields(target, source);
    expect(merged.spotlightDim, 60);
    expect(merged.spotlightEffect, SpotlightEffect.blur);
    expect(merged.spotlightFeather, 8);
    expect(merged.strength, 20);
    expect(merged.cornerRadius, 7.0); // per-hole field NOT copied
  });
}
