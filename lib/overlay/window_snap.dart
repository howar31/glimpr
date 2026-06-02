import 'dart:ui' show Offset, Rect;

/// The front-most window rect containing [p], or null. [windows] is ordered
/// front-to-back (capture-time z-order), so the FIRST containing rect is the
/// topmost — exactly what a click should snap to.
Rect? topmostWindowAt(List<Rect> windows, Offset p) {
  for (final w in windows) {
    if (w.contains(p)) return w;
  }
  return null;
}
