import 'dart:ui';
import 'draw_style.dart';
import 'text_metrics.dart';

/// One immutable annotation command. Variants per tool.
sealed class Drawable {
  final DrawStyle style;
  const Drawable(this.style);

  /// Logical bounding box (overlay-local logical coords).
  Rect get bounds;

  /// Returns a copy shifted by [delta].
  Drawable moved(Offset delta);
}

/// Shapes defined by an axis-aligned [rect] — resizable via corner handles.
/// Implemented by the rectangle/ellipse shapes (and the Wave-2 raster regions).
/// The corner-resize gesture and selection handles are shared across all of them.
abstract interface class RectShaped {
  Rect get rect;
  Drawable resizedTo(Rect r);
}

class RectangleDrawable extends Drawable implements RectShaped {
  @override
  final Rect rect;
  const RectangleDrawable(this.rect, DrawStyle style) : super(style);

  @override
  Rect get bounds => rect;

  @override
  RectangleDrawable moved(Offset d) => RectangleDrawable(rect.shift(d), style);

  @override
  RectangleDrawable resizedTo(Rect r) => RectangleDrawable(r, style);

  RectangleDrawable withStyle(DrawStyle s) => RectangleDrawable(rect, s);
}

class EllipseDrawable extends Drawable implements RectShaped {
  @override
  final Rect rect;
  const EllipseDrawable(this.rect, DrawStyle style) : super(style);

  @override
  Rect get bounds => rect;

  @override
  EllipseDrawable moved(Offset d) => EllipseDrawable(rect.shift(d), style);

  @override
  EllipseDrawable resizedTo(Rect r) => EllipseDrawable(r, style);

  EllipseDrawable withStyle(DrawStyle s) => EllipseDrawable(rect, s);
}

/// A plain straight stroke (an arrow with no head). Move-only.
class LineDrawable extends Drawable {
  final Offset start;
  final Offset end;
  const LineDrawable(this.start, this.end, DrawStyle style) : super(style);

  @override
  Rect get bounds => _segmentBounds(start, end);

  @override
  LineDrawable moved(Offset d) => LineDrawable(start + d, end + d, style);

  LineDrawable withStyle(DrawStyle s) => LineDrawable(start, end, s);
}

/// A thick, translucent marker stroke (drawn as a wide rounded line in the
/// painter at reduced opacity). Same geometry as a line; move-only.
class HighlighterDrawable extends Drawable {
  final Offset start;
  final Offset end;
  const HighlighterDrawable(this.start, this.end, DrawStyle style)
    : super(style);

  @override
  Rect get bounds => _segmentBounds(start, end);

  @override
  HighlighterDrawable moved(Offset d) =>
      HighlighterDrawable(start + d, end + d, style);

  HighlighterDrawable withStyle(DrawStyle s) =>
      HighlighterDrawable(start, end, s);
}

/// A freehand polyline through the captured pointer [points]. Move-only.
class PenDrawable extends Drawable {
  final List<Offset> points;
  const PenDrawable(this.points, DrawStyle style) : super(style);

  @override
  Rect get bounds {
    if (points.isEmpty) return Rect.zero;
    var minX = points.first.dx, minY = points.first.dy;
    var maxX = minX, maxY = minY;
    for (final p in points) {
      if (p.dx < minX) minX = p.dx;
      if (p.dy < minY) minY = p.dy;
      if (p.dx > maxX) maxX = p.dx;
      if (p.dy > maxY) maxY = p.dy;
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  @override
  PenDrawable moved(Offset d) =>
      PenDrawable([for (final p in points) p + d], style);

  PenDrawable appended(Offset p) => PenDrawable([...points, p], style);

  PenDrawable withStyle(DrawStyle s) => PenDrawable(points, s);
}

/// An auto-numbered step badge: a filled circle with a white number. Move-only;
/// tap-to-place. Radius derives from the style's font size.
class StepDrawable extends Drawable {
  final Offset center;
  final int number;
  const StepDrawable(this.center, this.number, DrawStyle style) : super(style);

  double get radius => style.fontSize.clamp(10.0, 80.0);

  @override
  Rect get bounds => Rect.fromCircle(center: center, radius: radius);

  @override
  StepDrawable moved(Offset d) => StepDrawable(center + d, number, style);

  StepDrawable withStyle(DrawStyle s) => StepDrawable(center, number, s);
}

/// Next badge number for a freshly placed [StepDrawable] = (max existing) + 1.
/// Computed from the document each placement so undo/redo/delete stay coherent.
int nextStepNumber(List<Drawable> drawables) {
  var maxN = 0;
  for (final d in drawables) {
    if (d is StepDrawable && d.number > maxN) maxN = d.number;
  }
  return maxN + 1;
}

/// A rectangular region that masks the pre-blurred whole-frame image (computed
/// once when the tool is selected). The drawable is just the rect; the painter
/// clips the shared blurred image to it. The [style] is carried for uniformity.
class BlurDrawable extends Drawable implements RectShaped {
  @override
  final Rect rect;
  const BlurDrawable(this.rect, DrawStyle style) : super(style);

  @override
  Rect get bounds => rect;

  @override
  BlurDrawable moved(Offset d) => BlurDrawable(rect.shift(d), style);

  @override
  BlurDrawable resizedTo(Rect r) => BlurDrawable(r, style);
}

/// A rectangular region that masks the pre-pixelated whole-frame image. Like
/// [BlurDrawable], the drawable is just the rect; the painter clips the shared
/// pixelated image to it (so there is no per-region async mosaic).
class PixelateDrawable extends Drawable implements RectShaped {
  @override
  final Rect rect;
  const PixelateDrawable(this.rect, DrawStyle style) : super(style);

  @override
  Rect get bounds => rect;

  @override
  PixelateDrawable moved(Offset d) => PixelateDrawable(rect.shift(d), style);

  @override
  PixelateDrawable resizedTo(Rect r) => PixelateDrawable(r, style);
}

/// A pasted bitmap (from the clipboard) drawn into [rect]. Movable/resizable.
class ImageDrawable extends Drawable implements RectShaped {
  @override
  final Rect rect;
  final Image image;
  const ImageDrawable(this.rect, this.image, DrawStyle style) : super(style);

  @override
  Rect get bounds => rect;

  @override
  ImageDrawable moved(Offset d) => ImageDrawable(rect.shift(d), image, style);

  @override
  ImageDrawable resizedTo(Rect r) => ImageDrawable(r, image, style);
}

Rect _segmentBounds(Offset a, Offset b) => Rect.fromLTRB(
  a.dx < b.dx ? a.dx : b.dx,
  a.dy < b.dy ? a.dy : b.dy,
  a.dx > b.dx ? a.dx : b.dx,
  a.dy > b.dy ? a.dy : b.dy,
);

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
      TextDrawable(position, [
        TextRun(text, style.color, style.fontSize),
      ], style);

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
