import 'package:flutter/foundation.dart';
import 'dart:ui' show Offset, Rect;

/// Holds the in-progress marquee rectangle (overlay-local logical coords).
/// A [ValueNotifier] so only the scrim repaints during a drag (the frozen
/// image stays static behind a RepaintBoundary).
class SelectionController {
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
    if (a != null) rect.value = Rect.fromPoints(a, to);
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
