import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/brush_texture.dart';
import 'package:glimpr/editor/draw_style.dart';

void main() {
  test('brushPhase lands inside one tile, negative seeds included', () {
    for (final s in [0, 1, 7, -1, -12345, 1 << 40]) {
      expect(brushPhase(s), inInclusiveRange(0, kBrushBandLength - 1),
          reason: 'seed $s');
    }
    expect(brushPhase(3), brushPhase(3), reason: 'deterministic');
    expect(brushPhase(3) == brushPhase(4), isFalse);
  });

  test('brushBakeSeed is distinct per texture', () {
    final seeds = {for (final t in HighlighterTexture.values) brushBakeSeed(t)};
    expect(seeds, hasLength(HighlighterTexture.values.length));
  });

  test('MarkerNoise is deterministic per seed and smooth in [0, 1]', () {
    final a = MarkerNoise(7), b = MarkerNoise(7), c = MarkerNoise(8);
    for (var x = 0.0; x < 20; x += 0.37) {
      expect(a(x), b(x));
      expect(a(x), inInclusiveRange(0, 1));
    }
    expect(a(3.3) == c(3.3), isFalse);
  });

  // Baking needs a live engine (toImageSync): a widget test provides one.
  testWidgets('bakes the band at the texture size and caches per texture',
      (tester) async {
    final cache = BrushTextures.instance..reset();
    addTearDown(cache.reset);
    final band = cache.band(HighlighterTexture.streaks);
    expect(band.width, kBrushBandLength);
    expect(band.height, kBrushBandWidth);
    expect(identical(cache.band(HighlighterTexture.streaks), band), isTrue);
    expect(identical(cache.band(HighlighterTexture.grain), band), isFalse);
    expect(cache.bakedCount, 2);
  });

  testWidgets('every textured style bakes its own band', (tester) async {
    final cache = BrushTextures.instance..reset();
    addTearDown(cache.reset);
    final textured = HighlighterTexture.values
        .where((t) => t != HighlighterTexture.clean)
        .toList();
    final bands = {for (final t in textured) t: cache.band(t)};
    expect(bands.values.toSet(), hasLength(textured.length));
    expect(cache.bakedCount, textured.length);
  });

  testWidgets('every textured recipe records a picture without throwing',
      (tester) async {
    for (final t in HighlighterTexture.values) {
      if (t == HighlighterTexture.clean) continue;
      await tester.pumpWidget(
        MaterialApp(
          home: CustomPaint(
            size: const Size(300, 60),
            painter: _BandPainter(t),
          ),
        ),
      );
      expect(tester.takeException(), isNull, reason: t.name);
    }
  });
}

class _BandPainter extends CustomPainter {
  final HighlighterTexture texture;
  _BandPainter(this.texture);
  @override
  void paint(Canvas canvas, Size size) =>
      paintBrushBand(canvas, texture, size.width, size.height, 3);
  @override
  bool shouldRepaint(_BandPainter old) => old.texture != texture;
}
