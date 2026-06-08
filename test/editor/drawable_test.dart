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
    const d = HighlighterDrawable([Offset(5, 5), Offset(45, 35)], style);
    expect(d.bounds, const Rect.fromLTRB(5, 5, 45, 35));
    final m = d.moved(const Offset(-5, -5));
    expect(m.points.first, const Offset(0, 0));
    expect(m.points.last, const Offset(40, 30));
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
}
