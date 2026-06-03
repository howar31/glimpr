import 'dart:ui' show Offset;
import '../capture/captured_display.dart';

/// The front-most window containing [p], or null. [windows] is ordered
/// front-to-back (capture-time z-order), so the FIRST containing one is the
/// topmost — exactly what a click should snap to.
SnapWindow? topmostWindowAt(List<SnapWindow> windows, Offset p) {
  for (final w in windows) {
    if (w.rect.contains(p)) return w;
  }
  return null;
}
