import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/editor/geometry.dart';

void main() {
  const a = Offset(10, 20);

  test('aspect 1.0 equals a square (max side), quadrant preserved', () {
    // dx=30, dy=-10 -> side = max(30,10)=30, signs (+,-)
    expect(aspectCorner(a, const Offset(40, 10), 1.0), const Offset(40, -10));
    // dx=-5, dy=8 -> side = 8, signs (-,+)
    expect(aspectCorner(a, const Offset(5, 28), 1.0), const Offset(2, 28));
  });

  test('aspect 2.0 yields width:height == 2:1, quadrant preserved', () {
    // dx=40, dy=5 -> w = max(40, 5*2)=40, h=20, signs (+,+)
    final r = aspectCorner(a, const Offset(50, 25), 2.0);
    expect(r, const Offset(50, 40));
    expect((r.dx - a.dx).abs() / (r.dy - a.dy).abs(), 2.0);
  });

  test('aspect 0.5 (tall) yields width:height == 1:2', () {
    // dx=10, dy=40 -> w = max(10, 40*0.5)=20, h=40, signs (+,+)
    final r = aspectCorner(a, const Offset(20, 60), 0.5);
    expect(r, const Offset(30, 60));
    expect((r.dx - a.dx).abs() / (r.dy - a.dy).abs(), 0.5);
  });

  test('binding axis grows to reach the cursor (height-bound on a wide aspect)', () {
    // mostly-vertical drag, wide aspect 3.0: dy*aspect dominates dx
    // dx=5, dy=30 -> w = max(5, 30*3)=90, h=30
    final r = aspectCorner(a, const Offset(15, 50), 3.0);
    expect(r, const Offset(100, 50));
  });
}
