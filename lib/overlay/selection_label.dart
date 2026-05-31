import 'dart:ui' show Rect;

/// Live dimension label in logical points, e.g. '1024 × 768'.
String selectionLabel(Rect r) => '${r.width.round()} × ${r.height.round()}';
