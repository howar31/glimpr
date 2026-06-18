import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/draw_style.dart';
import 'package:glimpr/editor/drawable.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const style = DrawStyle();

  test('rectangle bounds and move', () {
    const d = RectangleDrawable(Rect.fromLTWH(10, 20, 30, 40), style);
    expect(d.bounds, const Rect.fromLTWH(10, 20, 30, 40));
    final m = d.moved(const Offset(5, -5));
    expect(m.rect, const Rect.fromLTWH(15, 15, 30, 40));
  });

  test('arrow bounds is the points bounding box, move shifts both', () {
    const d = ArrowDrawable(Offset(0, 0), Offset(40, 30), style);
    expect(d.bounds, const Rect.fromLTRB(0, 0, 40, 30));
    final m = d.moved(const Offset(10, 10));
    expect(m.start, const Offset(10, 10));
    expect(m.end, const Offset(50, 40));
  });

  test('rectangle resizedTo replaces the rect', () {
    const d = RectangleDrawable(Rect.fromLTWH(0, 0, 10, 10), style);
    final r = d.resizedTo(const Rect.fromLTWH(0, 0, 20, 25));
    expect(r.rect, const Rect.fromLTWH(0, 0, 20, 25));
  });

  test('rectangle and ellipse are RectShaped (corner-resizable)', () {
    const rect = RectangleDrawable(Rect.fromLTWH(0, 0, 10, 10), style);
    const ell = EllipseDrawable(Rect.fromLTWH(0, 0, 10, 10), style);
    expect(rect, isA<RectShaped>());
    expect(ell, isA<RectShaped>());
  });

  test('ellipse bounds, move, resizedTo', () {
    const d = EllipseDrawable(Rect.fromLTWH(10, 20, 30, 40), style);
    expect(d.bounds, const Rect.fromLTWH(10, 20, 30, 40));
    expect(
      d.moved(const Offset(5, -5)).rect,
      const Rect.fromLTWH(15, 15, 30, 40),
    );
    expect(
      d.resizedTo(const Rect.fromLTWH(0, 0, 8, 9)).rect,
      const Rect.fromLTWH(0, 0, 8, 9),
    );
  });

  test('line bounds is the points bbox; move shifts both ends', () {
    const d = LineDrawable(Offset(0, 0), Offset(40, 30), style);
    expect(d.bounds, const Rect.fromLTRB(0, 0, 40, 30));
    final m = d.moved(const Offset(10, 10));
    expect(m.start, const Offset(10, 10));
    expect(m.end, const Offset(50, 40));
  });

  test('highlighter bounds is the points bbox; move shifts every point', () {
    final d = HighlighterDrawable([const Offset(5, 5), const Offset(45, 35)], style);
    expect(d.bounds, const Rect.fromLTRB(5, 5, 45, 35));
    final m = d.moved(const Offset(-5, -5));
    expect(m.points.first, const Offset(0, 0));
    expect(m.points.last, const Offset(40, 30));
  });

  group('highlighter texture seed is stable across transforms', () {
    test('default seed depends only on start, not the moving end', () {
      // While a stroke is drawn the END moves but the START is fixed; the
      // procedural marker texture must NOT re-randomize, so the default seed
      // ignores the end point.
      final a =
          HighlighterDrawable([const Offset(5, 5), const Offset(45, 35)], style);
      final b =
          HighlighterDrawable([const Offset(5, 5), const Offset(200, 99)], style);
      expect(a.seed, b.seed);
    });

    test('moved / withPoints / withEndpoints / withStyle preserve the seed', () {
      // A committed stroke being moved/resized/restyled keeps its texture.
      final d = HighlighterDrawable(
          [const Offset(5, 5), const Offset(45, 35)], style,
          seed: 12345);
      expect(d.moved(const Offset(10, 10)).seed, 12345);
      expect(d.withPoints([const Offset(1, 1), const Offset(2, 2)]).seed, 12345);
      expect(
          d.withEndpoints(const Offset(9, 9), const Offset(8, 8)).seed, 12345);
      expect(d.withStyle(const DrawStyle()).seed, 12345);
    });

    test('explicit seed overrides the start-derived default', () {
      final d = HighlighterDrawable(
          [const Offset(5, 5), const Offset(45, 35)], style,
          seed: 7);
      expect(d.seed, 7);
    });
  });

  test(
    'pen bounds is the point cloud bbox; move shifts every point; appended',
    () {
      const d = PenDrawable([
        Offset(0, 0),
        Offset(10, 30),
        Offset(20, 5),
      ], style);
      expect(d.bounds, const Rect.fromLTRB(0, 0, 20, 30));
      final m = d.moved(const Offset(1, 2));
      expect(m.points.first, const Offset(1, 2));
      expect(m.points.last, const Offset(21, 7));
      expect(d.appended(const Offset(30, 30)).points.length, 4);
    },
  );

  test('step bounds is the circle bbox; move shifts the center', () {
    final d = StepDrawable(const Offset(50, 50), 1, style);
    final r = d.radius;
    expect(d.bounds, Rect.fromCircle(center: const Offset(50, 50), radius: r));
    expect(d.moved(const Offset(10, 0)).center, const Offset(60, 50));
  });

  test('nextStepNumber = max existing step number + 1', () {
    expect(nextStepNumber(const []), 1);
    final list = <Drawable>[
      StepDrawable(const Offset(0, 0), 1, style),
      const RectangleDrawable(Rect.fromLTWH(0, 0, 5, 5), style),
      StepDrawable(const Offset(9, 9), 3, style), // gap (2 was deleted)
    ];
    expect(nextStepNumber(list), 4);
  });

  test('nextStepNumber honours the start floor', () {
    final list = <Drawable>[StepDrawable(const Offset(0, 0), 3, style)];
    // Empty doc: the floor IS the first number.
    expect(nextStepNumber(const [], start: 5), 5);
    // Existing max above the floor: continue from max (floor ignored).
    expect(nextStepNumber(list, start: 2), 4);
    // Floor above the running max: jump up to the floor.
    expect(nextStepNumber(list, start: 10), 10);
    // Default start = legacy behaviour.
    expect(nextStepNumber(list), 4);
  });

  test('text drawable carries position and text', () {
    final d = TextDrawable(const Offset(5, 6), 'hi', style);
    expect(d.position, const Offset(5, 6));
    expect(d.text, 'hi');
    expect(d.moved(const Offset(1, 1)).bounds.topLeft, const Offset(6, 7));
  });

  test('text drawable carries its single style', () {
    const d = TextDrawable(
      Offset(0, 0),
      'abc',
      DrawStyle(fontSize: 28, fontFamily: 'Courier'),
    );
    expect(d.text, 'abc');
    expect(d.style.fontSize, 28);
    expect(d.style.fontFamily, 'Courier');
    expect(d.withStyle(const DrawStyle(fontSize: 12)).style.fontSize, 12);
  });

  test('MagnifyDrawable derives destRect from source size * factor, centred', () {
    const m = MagnifyDrawable(Rect.fromLTWH(0, 0, 10, 10), Offset(100, 100),
        DrawStyle(magnifyFactor: 2.0));
    expect(m.rect, const Rect.fromLTWH(0, 0, 10, 10)); // RectShaped == source
    expect(m.destRect, const Rect.fromLTWH(90, 90, 20, 20)); // 20x20 @ (100,100)
    expect(m.bounds, const Rect.fromLTRB(0, 0, 110, 110)); // union
  });

  test('MagnifyDrawable moved shifts BOTH source and inset', () {
    const m = MagnifyDrawable(
        Rect.fromLTWH(0, 0, 10, 10), Offset(100, 100), DrawStyle());
    final m2 = m.moved(const Offset(5, 7));
    expect(m2.sourceRect, const Rect.fromLTWH(5, 7, 10, 10));
    expect(m2.destCenter, const Offset(105, 107));
  });

  test('MagnifyDrawable resizedTo replaces source; inset follows factor', () {
    const m = MagnifyDrawable(Rect.fromLTWH(0, 0, 10, 10), Offset(100, 100),
        DrawStyle(magnifyFactor: 2.0));
    final m2 = m.resizedTo(const Rect.fromLTWH(0, 0, 20, 10));
    expect(m2.sourceRect.width, 20);
    expect(m2.destRect.width, 40);
    expect(m2.destCenter, const Offset(100, 100));
  });

  test('MagnifyDrawable withDestCenter moves only the inset', () {
    const m = MagnifyDrawable(
        Rect.fromLTWH(0, 0, 10, 10), Offset(100, 100), DrawStyle());
    final m2 = m.withDestCenter(const Offset(50, 60));
    expect(m2.sourceRect, m.sourceRect);
    expect(m2.destCenter, const Offset(50, 60));
  });

  group('SpotlightDrawable', () {
    const style = DrawStyle();
    const rect = Rect.fromLTWH(10, 20, 100, 50);

    test('bounds == rect; moved shifts; resizedTo replaces', () {
      const d = SpotlightDrawable(rect, style);
      expect(d.bounds, rect);
      expect(d.moved(const Offset(5, -5)).rect,
          const Rect.fromLTWH(15, 15, 100, 50));
      const r2 = Rect.fromLTWH(0, 0, 30, 30);
      expect(d.resizedTo(r2).rect, r2);
    });

    test('withStyle keeps rect', () {
      const d = SpotlightDrawable(rect, style);
      final s2 = style.copyWith(spotlightDim: 10);
      expect(d.withStyle(s2).style.spotlightDim, 10);
      expect(d.withStyle(s2).rect, rect);
    });
  });
}
