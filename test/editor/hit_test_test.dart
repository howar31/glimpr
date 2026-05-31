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
}
