import 'dart:math' as math;

/// Landing-gallery grid sizing: tiles GROW with the window instead of leaving
/// dead space (the recents list is capped, so a large window used to strand
/// most of its area). Tile width is bounded to [kGalleryTileMin]..
/// [kGalleryTileMax]; the max keeps the ~256px thumbnail sidecars at
/// native-or-down scale (maxW / ratio ≈ 254px tall), so grown tiles never blur.
const double kGalleryTileMin = 170;
const double kGalleryTileMax = 310;
const double kGalleryTileRatio = 1.22; // whole cell, thumbnail + caption
const double kGallerySpacing = 8;

/// Column count for [count] tiles in a [width] x [height] viewport: the FEWEST
/// columns (= the largest tiles) whose tile width respects the max AND whose
/// rows all fit [height] without scrolling. When even minimum-size tiles
/// cannot fit, returns the densest min-size layout and the grid scrolls.
int galleryColumns(double width, double height, int count) {
  const s = kGallerySpacing;
  if (count <= 0 || width <= 0) return 1;
  final colsMin = math.max(1, ((width + s) / (kGalleryTileMax + s)).ceil());
  final colsCap =
      math.max(colsMin, ((width + s) / (kGalleryTileMin + s)).floor());
  for (var cols = colsMin; cols <= colsCap; cols++) {
    final tileW = (width - (cols - 1) * s) / cols;
    final rows = (count / cols).ceil();
    final tileH = tileW / kGalleryTileRatio;
    if (rows * tileH + (rows - 1) * s <= height) return cols;
  }
  return colsCap;
}
