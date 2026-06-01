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

  test('rectangle resized replaces the rect', () {
    const d = RectangleDrawable(Rect.fromLTWH(0, 0, 10, 10), style);
    final r = d.resized(const Rect.fromLTWH(0, 0, 20, 25));
    expect(r.rect, const Rect.fromLTWH(0, 0, 20, 25));
  });

  test('text drawable carries position and concatenated text', () {
    final d = TextDrawable.plain(const Offset(5, 6), 'hi', style);
    expect(d.position, const Offset(5, 6));
    expect(d.text, 'hi');
    expect(d.moved(const Offset(1, 1)).bounds.topLeft, const Offset(6, 7));
  });

  test('text drawable joins multiple runs into one string', () {
    const d = TextDrawable(
      Offset(0, 0),
      [TextRun('abc', Color(0xFFFF0000), 18), TextRun('123', Color(0xFF0000FF), 28)],
      style,
    );
    expect(d.text, 'abc123');
    expect(d.runs.length, 2);
  });
}
