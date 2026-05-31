import 'dart:ui';
import 'draw_style.dart';
import 'text_metrics.dart';

/// One immutable annotation command. Variants per Wave-1 tool.
sealed class Drawable {
  final DrawStyle style;
  const Drawable(this.style);

  /// Logical bounding box (overlay-local logical coords).
  Rect get bounds;

  /// Returns a copy shifted by [delta].
  Drawable moved(Offset delta);
}

class RectangleDrawable extends Drawable {
  final Rect rect;
  const RectangleDrawable(this.rect, DrawStyle style) : super(style);

  @override
  Rect get bounds => rect;

  @override
  RectangleDrawable moved(Offset d) => RectangleDrawable(rect.shift(d), style);

  RectangleDrawable resized(Rect r) => RectangleDrawable(r, style);

  RectangleDrawable withStyle(DrawStyle s) => RectangleDrawable(rect, s);
}

class ArrowDrawable extends Drawable {
  final Offset start;
  final Offset end;
  const ArrowDrawable(this.start, this.end, DrawStyle style) : super(style);

  @override
  Rect get bounds => Rect.fromLTRB(
        start.dx < end.dx ? start.dx : end.dx,
        start.dy < end.dy ? start.dy : end.dy,
        start.dx > end.dx ? start.dx : end.dx,
        start.dy > end.dy ? start.dy : end.dy,
      );

  @override
  ArrowDrawable moved(Offset d) => ArrowDrawable(start + d, end + d, style);

  ArrowDrawable resized(Rect r) =>
      ArrowDrawable(r.topLeft, r.bottomRight, style);

  ArrowDrawable withStyle(DrawStyle s) => ArrowDrawable(start, end, s);
}

class TextDrawable extends Drawable {
  final Offset position; // top-left
  final String text;
  const TextDrawable(this.position, this.text, DrawStyle style) : super(style);

  @override
  Rect get bounds => position & measureText(this);

  @override
  TextDrawable moved(Offset d) => TextDrawable(position + d, text, style);

  TextDrawable withText(String t) => TextDrawable(position, t, style);
  TextDrawable withStyle(DrawStyle s) => TextDrawable(position, text, s);
}
