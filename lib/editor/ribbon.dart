import 'dart:ui';

/// Pure geometry for a texture-mapped band ("ribbon") along a polyline: the
/// highlighter paints its brush texture this way, one triangle strip per
/// stroke, so the cost per frame is a single textured draw whatever the
/// texture looks like.

/// Unit normal at each vertex of [spine] — perpendicular to the chord through
/// the vertex's neighbours (the end vertices use their single neighbour), so a
/// band offset by these runs parallel to the curve. A degenerate chord yields
/// the +y normal.
List<Offset> spineNormals(List<Offset> spine) {
  final normals = <Offset>[];
  for (var j = 0; j < spine.length; j++) {
    final a = spine[j == 0 ? 0 : j - 1];
    final b = spine[j == spine.length - 1 ? j : j + 1];
    var t = b - a;
    final l = t.distance;
    t = l == 0 ? const Offset(1, 0) : t / l;
    normals.add(Offset(-t.dy, t.dx));
  }
  return normals;
}

/// The triangle-strip mesh of a band of [width] centred on [spine]: two
/// vertices per spine vertex (offset by half the width along the normal on
/// either side). Texture coordinates keep the texture's ASPECT: v spans
/// [texHeight] across the band, and u advances by the same texels-per-px
/// along the arc length (so a seamless texture TILES along the stroke instead
/// of stretching over it, and its features stay the same size whatever the
/// stroke length). [uOffset] shifts the tiling phase (per-stroke variety).
({List<Offset> positions, List<Offset> uvs}) ribbonMesh(
  List<Offset> spine,
  double width, {
  required double texHeight,
  double uOffset = 0,
}) {
  final positions = <Offset>[];
  final uvs = <Offset>[];
  if (spine.isEmpty) return (positions: positions, uvs: uvs);
  final normals = spineNormals(spine);
  final texelsPerPx = width <= 0 ? 0.0 : texHeight / width;
  final half = width / 2;
  var arc = 0.0;
  for (var j = 0; j < spine.length; j++) {
    if (j > 0) arc += (spine[j] - spine[j - 1]).distance;
    final u = uOffset + arc * texelsPerPx;
    positions.add(spine[j] + normals[j] * half);
    positions.add(spine[j] - normals[j] * half);
    uvs.add(Offset(u, 0));
    uvs.add(Offset(u, texHeight));
  }
  return (positions: positions, uvs: uvs);
}
