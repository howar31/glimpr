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

/// Shapes defined by a list of control points the curve passes THROUGH —
/// `[start, ...interior, end]`. Implemented by line/arrow/highlighter. Adjustable
/// via a handle at each point; the endpoint-drag gesture + the per-point selection
/// handles are shared. With no interior points it is a straight 2-point segment.
abstract interface class Segmented {
  Offset get start;
  Offset get end;

  /// All control points: `[start, ...interior, end]` (>= 2).
  List<Offset> get points;

  /// Move the endpoints, preserving the interior control points.
  Drawable withEndpoints(Offset start, Offset end);

  /// Replace all control points (>= 2; first/last become start/end).
  Drawable withPoints(List<Offset> points);
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

/// A stroke through `[start, ...mids, end]` (Catmull-Rom curve; straight with no
/// mids). An arrow with no head. A handle per control point.
class LineDrawable extends Drawable implements Segmented {
  @override
  final Offset start;
  @override
  final Offset end;
  final List<Offset> mids; // interior control points
  const LineDrawable(this.start, this.end, DrawStyle style,
      {this.mids = const []})
      : super(style);

  @override
  List<Offset> get points => [start, ...mids, end];

  @override
  Rect get bounds => _pointsBounds(points);

  @override
  LineDrawable moved(Offset d) => LineDrawable(start + d, end + d, style,
      mids: [for (final m in mids) m + d]);

  @override
  LineDrawable withEndpoints(Offset start, Offset end) =>
      LineDrawable(start, end, style, mids: mids);

  @override
  LineDrawable withPoints(List<Offset> p) => LineDrawable(p.first, p.last, style,
      mids: p.length > 2 ? p.sublist(1, p.length - 1) : const []);

  LineDrawable withStyle(DrawStyle s) =>
      LineDrawable(start, end, s, mids: mids);
}

/// A freehand translucent marker band through the captured pointer [points].
/// The painter draws a wide rounded band and composites the WHOLE stroke at the
/// colour's alpha in one layer, so self-overlap doesn't darken (the highlighter
/// look) and the chosen alpha is honoured. Move-only.
class HighlighterDrawable extends Drawable implements Segmented {
  @override
  final List<Offset> points;
  const HighlighterDrawable(this.points, DrawStyle style) : super(style);

  // The band follows the Catmull-Rom curve through `points`; the endpoints are
  // the first/last points and the rest are interior control points.
  @override
  Offset get start => points.first;
  @override
  Offset get end => points.last;
  @override
  HighlighterDrawable withEndpoints(Offset start, Offset end) =>
      HighlighterDrawable([
        start,
        if (points.length > 2) ...points.sublist(1, points.length - 1),
        end,
      ], style);
  @override
  HighlighterDrawable withPoints(List<Offset> p) =>
      HighlighterDrawable(p, style);

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
  HighlighterDrawable moved(Offset d) =>
      HighlighterDrawable([for (final p in points) p + d], style);

  HighlighterDrawable withStyle(DrawStyle s) => HighlighterDrawable(points, s);
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

/// Next badge number for a freshly placed [StepDrawable]: the running max + 1,
/// but never below the [start] floor (so a sequence can begin at N). Computed from
/// the document each placement so undo/redo/delete stay coherent. Default
/// start = 1 reproduces the legacy auto-from-1 numbering.
int nextStepNumber(List<Drawable> drawables, {int start = 1}) {
  var maxN = start - 1;
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

  BlurDrawable withStyle(DrawStyle s) => BlurDrawable(rect, s);
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

  PixelateDrawable withStyle(DrawStyle s) => PixelateDrawable(rect, s);
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

/// A magnify callout: the [sourceRect] region of the base image, drawn enlarged
/// (by `style.magnifyFactor`) as an inset centred at [destCenter]. RectShaped on
/// the SOURCE, so the source reuses the corner-resize handles; the inset size is
/// DERIVED (no independent size).
class MagnifyDrawable extends Drawable implements RectShaped {
  final Rect sourceRect;
  final Offset destCenter;
  const MagnifyDrawable(this.sourceRect, this.destCenter, DrawStyle style)
      : super(style);

  @override
  Rect get rect => sourceRect;

  Size get destSize => sourceRect.size * style.magnifyFactor;
  Rect get destRect => Rect.fromCenter(
      center: destCenter, width: destSize.width, height: destSize.height);

  @override
  Rect get bounds => sourceRect.expandToInclude(destRect);

  @override
  MagnifyDrawable moved(Offset d) =>
      MagnifyDrawable(sourceRect.shift(d), destCenter + d, style);

  @override
  MagnifyDrawable resizedTo(Rect r) => MagnifyDrawable(r, destCenter, style);

  MagnifyDrawable withDestCenter(Offset c) =>
      MagnifyDrawable(sourceRect, c, style);

  MagnifyDrawable withStyle(DrawStyle s) =>
      MagnifyDrawable(sourceRect, destCenter, s);
}

/// A spotlight hole: everything OUTSIDE the union of all spotlight rects is
/// dimmed (and optionally blurred/pixelated) by ONE shared background layer the
/// painter renders; this drawable is just one bright hole in it. Layer-wide
/// params (dim/effect/strength/feather) ride the style and are kept equal across
/// all spotlights by the controller; rect + cornerRadius are per-hole.
class SpotlightDrawable extends Drawable implements RectShaped {
  @override
  final Rect rect;
  const SpotlightDrawable(this.rect, DrawStyle style) : super(style);

  @override
  Rect get bounds => rect;

  @override
  SpotlightDrawable moved(Offset d) => SpotlightDrawable(rect.shift(d), style);

  @override
  SpotlightDrawable resizedTo(Rect r) => SpotlightDrawable(r, style);

  SpotlightDrawable withStyle(DrawStyle s) => SpotlightDrawable(rect, s);
}

/// Bounding box of a list of control points (>= 1).
Rect _pointsBounds(List<Offset> pts) {
  var minX = pts.first.dx, minY = pts.first.dy;
  var maxX = minX, maxY = minY;
  for (final p in pts) {
    if (p.dx < minX) minX = p.dx;
    if (p.dy < minY) minY = p.dy;
    if (p.dx > maxX) maxX = p.dx;
    if (p.dy > maxY) maxY = p.dy;
  }
  return Rect.fromLTRB(minX, minY, maxX, maxY);
}

class ArrowDrawable extends Drawable implements Segmented {
  @override
  final Offset start;
  @override
  final Offset end;
  final List<Offset> mids; // interior control points
  const ArrowDrawable(this.start, this.end, DrawStyle style,
      {this.mids = const []})
      : super(style);

  @override
  List<Offset> get points => [start, ...mids, end];

  @override
  Rect get bounds => _pointsBounds(points);

  @override
  ArrowDrawable moved(Offset d) => ArrowDrawable(start + d, end + d, style,
      mids: [for (final m in mids) m + d]);

  @override
  ArrowDrawable withEndpoints(Offset start, Offset end) =>
      ArrowDrawable(start, end, style, mids: mids);

  @override
  ArrowDrawable withPoints(List<Offset> p) => ArrowDrawable(
      p.first, p.last, style,
      mids: p.length > 2 ? p.sublist(1, p.length - 1) : const []);

  ArrowDrawable resized(Rect r) =>
      ArrowDrawable(r.topLeft, r.bottomRight, style);

  ArrowDrawable withStyle(DrawStyle s) => ArrowDrawable(start, end, s, mids: mids);
}

/// A text annotation: a single string at [position], drawn in one [style]
/// (colour + size + font family). Text annotations carry one uniform style —
/// per-character styling is intentionally out of scope for a screenshot tool.
class TextDrawable extends Drawable {
  final Offset position; // top-left
  final String text;
  const TextDrawable(this.position, this.text, DrawStyle style) : super(style);

  @override
  Rect get bounds {
    final textRect = position & measureText(this);
    // A visible background pill grows the selectable / hittable area to wrap it;
    // with no background the bounds are the bare text rect (byte-identical).
    return style.fillColor.a > 0
        ? textBackgroundRect(textRect, style.fontSize)
        : textRect;
  }

  @override
  TextDrawable moved(Offset d) => TextDrawable(position + d, text, style);

  // Whole-object restyle — used when a text is selected and the toolbar style
  // changes, or to apply the live style while editing.
  TextDrawable withStyle(DrawStyle s) => TextDrawable(position, text, s);
}
