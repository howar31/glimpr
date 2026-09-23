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
/// either side), with texture coordinates that stretch the WHOLE texture
/// ([texWidth] x [texHeight]) along the band's arc length (u) and across it
/// (v). A zero-length spine maps every vertex to u = 0.
({List<Offset> positions, List<Offset> uvs}) ribbonMesh(
  List<Offset> spine,
  double width, {
  required double texWidth,
  required double texHeight,
}) {
  final positions = <Offset>[];
  final uvs = <Offset>[];
  if (spine.isEmpty) return (positions: positions, uvs: uvs);
  final normals = spineNormals(spine);
  final cum = <double>[0];
  for (var j = 1; j < spine.length; j++) {
    cum.add(cum[j - 1] + (spine[j] - spine[j - 1]).distance);
  }
  final total = cum.last;
  final half = width / 2;
  for (var j = 0; j < spine.length; j++) {
    final u = total == 0 ? 0.0 : cum[j] / total * texWidth;
    positions.add(spine[j] + normals[j] * half);
    positions.add(spine[j] - normals[j] * half);
    uvs.add(Offset(u, 0));
    uvs.add(Offset(u, texHeight));
  }
  return (positions: positions, uvs: uvs);
}
