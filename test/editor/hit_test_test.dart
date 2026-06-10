import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/draw_style.dart';
import 'package:glimpr/editor/drawable.dart';
import 'package:glimpr/editor/hit_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const style = DrawStyle();

  test('returns topmost (last) drawable under the point', () {
    final list = <Drawable>[
      const RectangleDrawable(Rect.fromLTWH(0, 0, 100, 100), style),
      const RectangleDrawable(Rect.fromLTWH(20, 20, 30, 30), style),
    ];
    expect(hitTestTop(list, const Offset(35, 35)), 1); // inside both -> top
    expect(hitTestTop(list, const Offset(5, 5)), 0); // only the big one
    expect(hitTestTop(list, const Offset(300, 300)), isNull);
  });

  test('arrow hit uses a tolerance band around the segment', () {
    final list = <Drawable>[
      const ArrowDrawable(Offset(0, 0), Offset(100, 0), style),
    ];
    expect(hitTestTop(list, const Offset(50, 3)), 0); // within band
    expect(hitTestTop(list, const Offset(50, 40)), isNull);
  });

  test('ellipse hit is inside the oval, not the bbox corners', () {
    final list = <Drawable>[
      const EllipseDrawable(Rect.fromLTWH(0, 0, 100, 50), style),
    ];
    expect(hitTestTop(list, const Offset(50, 25)), 0); // center -> inside
    expect(
      hitTestTop(list, const Offset(2, 2)),
      isNull,
    ); // bbox corner, outside oval
    expect(hitTestTop(list, const Offset(200, 25)), isNull);
  });

  test('line and highlighter hit a band around the segment', () {
    final line = <Drawable>[
      const LineDrawable(Offset(0, 0), Offset(100, 0), style),
    ];
    expect(hitTestTop(line, const Offset(50, 3)), 0);
    expect(hitTestTop(line, const Offset(50, 40)), isNull);
    // Highlighter is wide (5x), so a point well off the centerline still hits.
    final hl = <Drawable>[
      const HighlighterDrawable([Offset(0, 0), Offset(100, 0)], style),
    ];
    expect(hitTestTop(hl, const Offset(50, 9)), 0); // inside the wide band
  });

  test('pen hit is the min distance to any segment of the polyline', () {
    final list = <Drawable>[
      const PenDrawable([Offset(0, 0), Offset(50, 0), Offset(50, 50)], style),
    ];
    expect(hitTestTop(list, const Offset(25, 2)), 0); // near first segment
    expect(hitTestTop(list, const Offset(52, 25)), 0); // near second segment
    expect(hitTestTop(list, const Offset(10, 40)), isNull); // far from both
  });

  test('step hit is within the badge radius', () {
    final list = <Drawable>[StepDrawable(const Offset(50, 50), 1, style)];
    expect(hitTestTop(list, const Offset(50, 50)), 0);
    expect(hitTestTop(list, const Offset(200, 200)), isNull);
  });

  test('magnify hits the source OR the inset, misses elsewhere', () {
    const m = MagnifyDrawable(Rect.fromLTWH(0, 0, 10, 10), Offset(100, 100),
        DrawStyle(magnifyFactor: 2.0));
    expect(hitTestTop([m], const Offset(5, 5)), 0); // in source
    expect(hitTestTop([m], const Offset(100, 100)), 0); // in inset
    expect(hitTestTop([m], const Offset(50, 50)), isNull); // neither
  });
}
