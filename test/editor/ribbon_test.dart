import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/ribbon.dart';

void main() {
  group('spineNormals', () {
    test('a horizontal spine has +y normals (unit length)', () {
      final n = spineNormals([const Offset(0, 0), const Offset(10, 0)]);
      expect(n, [const Offset(0, 1), const Offset(0, 1)]);
    });

    test('interior normals use the chord through the neighbours', () {
      // Right angle: the middle normal bisects the turn.
      final n = spineNormals([
        const Offset(0, 0),
        const Offset(10, 0),
        const Offset(10, 10),
      ]);
      expect(n[1].distance, closeTo(1, 1e-9));
      expect(n[1].dx, closeTo(-1 / 1.4142135, 1e-6));
      expect(n[1].dy, closeTo(1 / 1.4142135, 1e-6));
    });

    test('a degenerate chord falls back to +y', () {
      final n = spineNormals([const Offset(3, 3), const Offset(3, 3)]);
      expect(n, [const Offset(0, 1), const Offset(0, 1)]);
    });
  });

  group('ribbonMesh', () {
    test('two vertices per spine vertex, offset by half the width', () {
      final m = ribbonMesh(
        [const Offset(0, 0), const Offset(100, 0)],
        20,
        texHeight: 128,
      );
      expect(m.positions, [
        const Offset(0, 10),
        const Offset(0, -10),
        const Offset(100, 10),
        const Offset(100, -10),
      ]);
    });

    test('u advances at the texture aspect (texels per px = texH / width)', () {
      // Width 32 -> 4 texels per px; arc lengths 0, 30, 70.
      final m = ribbonMesh(
        [const Offset(0, 0), const Offset(30, 0), const Offset(30, 40)],
        32,
        texHeight: 128,
      );
      expect(m.uvs[0], const Offset(0, 0));
      expect(m.uvs[1], const Offset(0, 128));
      expect(m.uvs[2].dx, closeTo(120, 1e-9));
      expect(m.uvs[4].dx, closeTo(280, 1e-9));
      expect(m.uvs[5], const Offset(280, 128));
    });

    test('u does not depend on the stroke length (tiling, not stretching)',
        () {
      final short = ribbonMesh(
          [const Offset(0, 0), const Offset(50, 0)], 10, texHeight: 128);
      final long = ribbonMesh(
          [const Offset(0, 0), const Offset(50, 0), const Offset(500, 0)], 10,
          texHeight: 128);
      expect(long.uvs[2].dx, short.uvs[2].dx);
    });

    test('uOffset shifts the tiling phase', () {
      final m = ribbonMesh([const Offset(0, 0), const Offset(10, 0)], 10,
          texHeight: 128, uOffset: 300);
      expect(m.uvs[0].dx, 300);
      expect(m.uvs[2].dx, closeTo(300 + 128, 1e-9));
    });

    test('a zero-length spine maps every vertex to the phase', () {
      final m = ribbonMesh([const Offset(5, 5), const Offset(5, 5)], 4,
          texHeight: 128, uOffset: 7);
      expect(m.uvs.every((uv) => uv.dx == 7), isTrue);
    });

    test('an empty spine yields an empty mesh', () {
      final m = ribbonMesh(const [], 4, texHeight: 128);
      expect(m.positions, isEmpty);
      expect(m.uvs, isEmpty);
    });
  });
}
