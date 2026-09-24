import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/overlay/selection_guides.dart';
import 'package:glimpr/overlay/selection_scrim.dart';

void main() {
  const r = Rect.fromLTWH(100, 200, 300, 150); // right 400, bottom 350

  test('none + no center draws nothing', () {
    expect(guideSegments(r, lines: GuideLines.none), isEmpty);
    expect(guideCenterMark(r, center: false), isEmpty);
    expect(guidesConfigured(GuideLines.none, false), isFalse);
    expect(guidesConfigured(GuideLines.grid, false), isTrue);
    expect(guidesConfigured(GuideLines.none, true), isTrue);
  });

  test('grid = rule of thirds: two verticals + two horizontals', () {
    final s = guideSegments(r, lines: GuideLines.grid);
    expect(s, hasLength(4));
    expect(s, contains((const Offset(200, 200), const Offset(200, 350))));
    expect(s, contains((const Offset(300, 200), const Offset(300, 350))));
    expect(s, contains((const Offset(100, 250), const Offset(400, 250))));
    expect(s, contains((const Offset(100, 300), const Offset(400, 300))));
  });

  test('diagonals = the two corner-to-corner lines', () {
    final s = guideSegments(r, lines: GuideLines.diagonals);
    expect(s, hasLength(2));
    expect(s, contains((const Offset(100, 200), const Offset(400, 350))));
    expect(s, contains((const Offset(400, 200), const Offset(100, 350))));
  });

  test('center mark = a tiny plus with 2px arms, independent of the lines',
      () {
    expect(kGuideCenterArm, 2);
    final s = guideCenterMark(r, center: true);
    expect(s, hasLength(2));
    expect(s, contains((const Offset(248, 275), const Offset(252, 275))));
    expect(s, contains((const Offset(250, 273), const Offset(250, 277))));
    // The lines API never includes the mark (drawn solid, separately).
    expect(guideSegments(r, lines: GuideLines.grid), hasLength(4));
  });

  test('a small selection draws nothing (either side under kGuideMinSide)', () {
    const narrow = Rect.fromLTWH(0, 0, 79, 500);
    const short = Rect.fromLTWH(0, 0, 500, 79);
    const ok = Rect.fromLTWH(0, 0, 80, 80);
    expect(guideSegments(narrow, lines: GuideLines.grid), isEmpty);
    expect(guideCenterMark(narrow, center: true), isEmpty);
    expect(guideSegments(short, lines: GuideLines.grid), isEmpty);
    expect(guideSegments(ok, lines: GuideLines.grid), hasLength(4));
    expect(guideCenterMark(ok, center: true), hasLength(2));
  });

  test('SelectionGuidesPainter repaints only on rect / option change', () {
    const a = SelectionGuidesPainter(rect: r, lines: GuideLines.grid, center: true);
    const same =
        SelectionGuidesPainter(rect: r, lines: GuideLines.grid, center: true);
    final moved = SelectionGuidesPainter(
        rect: r.shift(const Offset(1, 0)), lines: GuideLines.grid, center: true);
    const noCenter =
        SelectionGuidesPainter(rect: r, lines: GuideLines.grid, center: false);
    expect(a.shouldRepaint(same), isFalse);
    expect(a.shouldRepaint(moved), isTrue);
    expect(a.shouldRepaint(noCenter), isTrue);
    const inverted = SelectionGuidesPainter(
        rect: r, lines: GuideLines.grid, center: true, invert: true);
    expect(a.shouldRepaint(inverted), isTrue);
  });
}
