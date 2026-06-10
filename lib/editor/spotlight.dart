import 'draw_style.dart';
import 'drawable.dart';

/// Pure helpers for the spotlight tool's ONE shared background layer (a dim +
/// optional blur/pixelate wash over the whole canvas with every spotlight rect
/// punched out as a feathered bright hole). Pure so they are unit-testable —
/// the painter itself cannot be headless-rasterized.

/// MaskFilter sigma for a hole's feathered edge. The 0.5 factor maps the
/// user-facing "feather" (≈ visible falloff width in logical px) to a gaussian
/// sigma; tuned on-device.
double spotlightSigma(double feather) => feather * 0.5;

/// Drawables painted UNDER the spotlight layer (treated as part of the
/// photograph): the raster regions. Everything else (ink, text, images, the
/// spotlights themselves) paints above so annotations never get dimmed.
bool paintsUnderSpotlight(Drawable d) =>
    d is BlurDrawable || d is PixelateDrawable;

/// The style carrying the layer-wide params, or null when the document has no
/// spotlight. The LAST (topmost) spotlight wins; the controller keeps the
/// layer-wide fields equal across all spotlights, so this is just "any".
DrawStyle? spotlightLayerStyle(List<Drawable> drawables) {
  DrawStyle? found;
  for (final d in drawables) {
    if (d is SpotlightDrawable) found = d.style;
  }
  return found;
}

/// Copy the LAYER-WIDE spotlight fields (dim / effect / strength / feather)
/// from [source] onto [target], preserving [target]'s per-hole fields
/// (cornerRadius) and everything else.
DrawStyle mergeSpotlightLayerFields(DrawStyle target, DrawStyle source) =>
    target.copyWith(
      spotlightDim: source.spotlightDim,
      spotlightEffect: source.spotlightEffect,
      spotlightFeather: source.spotlightFeather,
      strength: source.strength,
    );
