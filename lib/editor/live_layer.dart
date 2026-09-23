import 'drawable.dart';
import 'spotlight.dart';

/// Split the annotation content into the SETTLED layer (the document plus any
/// in-place edit) and the LIVE layer (the shape being drawn right now), so a
/// drag only re-rasterizes the live layer while the settled one stays cached.
///
/// A live candidate that must composite WITH the settled content joins the
/// settled list instead: a spotlight (all holes share one background layer)
/// and the raster regions (they paint under the spotlight dim). Order within
/// each list follows the input order.
({List<Drawable> settled, List<Drawable> live}) partitionLiveLayer(
  List<Drawable> settled,
  List<Drawable> live,
) {
  final s = List<Drawable>.of(settled);
  final l = <Drawable>[];
  for (final d in live) {
    if (d is SpotlightDrawable || paintsUnderSpotlight(d)) {
      s.add(d);
    } else {
      l.add(d);
    }
  }
  return (settled: s, live: l);
}
