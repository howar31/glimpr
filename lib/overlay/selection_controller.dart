import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;
import 'package:flutter/foundation.dart';

/// The selection rect for a cursor drag between [a] and [b] (logical coords):
/// both endpoints' AIMED pixels — the loupe/readout's round(v * scale - 0.5)
/// — end up INSIDE the marquee: [min, max + 1) per axis in native px, mapped
/// back to logical. A plain Rect.fromPoints(a, b) is half-open: whichever
/// endpoint held the larger coordinate had its pixel EXCLUDED, so every drag
/// silently missed one row/column of what the loupe showed in hand.
Rect aimedSelectionRect(Offset a, Offset b, double scale) {
  int aim(double v) => (v * scale - 0.5).round();
  double lo(double p, double q) => math.min(aim(p), aim(q)) / scale;
  double hi(double p, double q) => (math.max(aim(p), aim(q)) + 1) / scale;
  return Rect.fromLTRB(
      lo(a.dx, b.dx), lo(a.dy, b.dy), hi(a.dx, b.dx), hi(a.dy, b.dy));
}

/// Holds the in-progress marquee rectangle (overlay-local logical coords).
/// A [ValueNotifier] so only the scrim repaints during a drag (the frozen
/// image stays static behind a RepaintBoundary).
class SelectionController {
  /// Optional cursor-drag rect builder (e.g. [aimedSelectionRect] bound to the
  /// display scale). Applies to [update] only: programmatic rects ([set] —
  /// handles, move, element/window snap) are already exact pixel ranges.
  SelectionController([this._buildRect]);

  final Rect Function(Offset a, Offset b)? _buildRect;
  final ValueNotifier<Rect?> rect = ValueNotifier<Rect?>(null);
  Offset? _anchor;

  /// The drag's anchor (begin point, or the top-left after a [set]); used to
  /// constrain an in-progress selection (e.g. Shift -> square).
  Offset? get anchor => _anchor;

  void begin(Offset at) {
    _anchor = at;
    rect.value = Rect.fromPoints(at, at);
  }

  void update(Offset to) {
    final a = _anchor;
    if (a == null) return;
    rect.value = _buildRect?.call(a, to) ?? Rect.fromPoints(a, to);
  }

  /// Replace the rectangle outright (used to resize / move a pending selection),
  /// anchoring at its top-left so a subsequent [update] extends from there.
  void set(Rect r) {
    _anchor = r.topLeft;
    rect.value = r;
  }

  void clear() {
    _anchor = null;
    rect.value = null;
  }

  void dispose() => rect.dispose();
}
