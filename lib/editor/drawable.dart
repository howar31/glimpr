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

/// One styled segment of a [TextDrawable] — supports per-span color + size so a
/// single text object can mix styles (e.g. "abc" red, "123" blue and larger).
class TextRun {
  final String text;
  final Color color;
  final double fontSize;
  const TextRun(this.text, this.color, this.fontSize);

  @override
  bool operator ==(Object other) =>
      other is TextRun &&
      other.text == text &&
      other.color == color &&
      other.fontSize == fontSize;
  @override
  int get hashCode => Object.hash(text, color, fontSize);
}

class TextDrawable extends Drawable {
  final Offset position; // top-left
  final List<TextRun> runs;
  const TextDrawable(this.position, this.runs, DrawStyle style) : super(style);

  /// Convenience for a single-style text (tests, simple callers).
  factory TextDrawable.plain(Offset position, String text, DrawStyle style) =>
      TextDrawable(position, [TextRun(text, style.color, style.fontSize)], style);

  String get text => runs.map((r) => r.text).join();

  @override
  Rect get bounds => position & measureText(this);

  @override
  TextDrawable moved(Offset d) => TextDrawable(position + d, runs, style);

  TextDrawable withRuns(List<TextRun> r) => TextDrawable(position, r, style);

  // Whole-object restyle (flattens to one style) — used when a text is selected
  // and the toolbar style changes while NOT editing it.
  TextDrawable withStyle(DrawStyle s) =>
      TextDrawable(position, [TextRun(text, s.color, s.fontSize)], s);
}
