import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/brush_texture.dart';

void main() {
  test('brushVariant wraps into range, negative seeds included', () {
    expect(brushVariant(0), 0);
    expect(brushVariant(kBrushVariants), 0);
    expect(brushVariant(kBrushVariants + 1), 1);
    expect(brushVariant(-1), kBrushVariants - 1);
  });

  test('brushVariantSeed is distinct per variant', () {
    final seeds = {for (var v = 0; v < kBrushVariants; v++) brushVariantSeed(v)};
    expect(seeds, hasLength(kBrushVariants));
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
  testWidgets('bakes the band at the texture size and caches per variant',
      (tester) async {
    final cache = BrushTextures.instance..reset();
    addTearDown(cache.reset);
    final band = cache.band(5);
    expect(band.width, kBrushBandLength);
    expect(band.height, kBrushBandWidth);
    expect(identical(cache.band(5), band), isTrue, reason: 'same seed');
    expect(identical(cache.band(5 + kBrushVariants), band), isTrue,
        reason: 'same variant');
    expect(identical(cache.band(6), band), isFalse, reason: 'other variant');
    expect(cache.bakedCount, 2);
  });

  testWidgets('paintStreakBand records a picture without throwing',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CustomPaint(
          size: const Size(300, 60),
          painter: _BandPainter(),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}

class _BandPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) =>
      paintStreakBand(canvas, size.width, size.height, 3);
  @override
  bool shouldRepaint(_BandPainter old) => false;
}
