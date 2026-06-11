import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/image_editor/gallery_layout.dart';

double _tileW(double width, int cols) =>
    (width - (cols - 1) * kGallerySpacing) / cols;

void main() {
  group('galleryColumns', () {
    test('big window: tiles grow but all rows fit unscrolled', () {
      final cols = galleryColumns(2500, 1300, 30);
      final w = _tileW(2500, cols);
      expect(w, greaterThanOrEqualTo(kGalleryTileMin));
      expect(w, lessThanOrEqualTo(kGalleryTileMax));
      final rows = (30 / cols).ceil();
      final total =
          rows * (w / kGalleryTileRatio) + (rows - 1) * kGallerySpacing;
      expect(total, lessThanOrEqualTo(1300));
      // Larger than the old fixed 190 extent — the point of the change.
      expect(w, greaterThan(190));
    });

    test('small window: falls back to densest min-size layout and scrolls',
        () {
      final cols = galleryColumns(1004, 500, 30);
      final w = _tileW(1004, cols);
      expect(w, greaterThanOrEqualTo(kGalleryTileMin));
      // The next column count would dip below the minimum tile width.
      expect(_tileW(1004, cols + 1), lessThan(kGalleryTileMin));
    });

    test('few items in a huge window stay capped at the max tile size', () {
      final cols = galleryColumns(2000, 1200, 2);
      expect(_tileW(2000, cols), lessThanOrEqualTo(kGalleryTileMax));
    });

    test('fewer columns would always overflow either cap or height', () {
      const width = 1990.0, height = 850.0, count = 30;
      final cols = galleryColumns(width, height, count);
      expect(cols, greaterThan(1));
      final fewer = cols - 1;
      final w = _tileW(width, fewer);
      final rows = (count / fewer).ceil();
      final total =
          rows * (w / kGalleryTileRatio) + (rows - 1) * kGallerySpacing;
      // The chosen count is minimal: one fewer column breaks a constraint.
      expect(w > kGalleryTileMax || total > height, isTrue);
    });

    test('degenerate inputs are safe', () {
      expect(galleryColumns(0, 500, 30), 1);
      expect(galleryColumns(1200, 0, 0), 1);
      expect(galleryColumns(-5, -5, 5), 1);
    });
  });
}
