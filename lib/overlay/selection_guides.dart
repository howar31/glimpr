import 'dart:ui';

/// Which composition lines the crop selection shows inside itself (Settings >
/// Selection & HUD). The center mark is a separate, independent option.
enum GuideLines { none, grid, diagonals }

/// Selections with either side below this (logical px) draw no guides: a small
/// box needs no composition aid and the lines would only cover its content.
const double kGuideMinSide = 80;

/// Half-length of each center-mark arm (logical px): a tiny solid plus that
/// only marks the exact center, not a crosshair (owner ruling 2026-09-23).
const double kGuideCenterArm = 2;

/// Guide dash length == gap (logical px): a fine, even two-tone dash, finer
/// than the selection border's 5/5 so the guides read as secondary.
const double kGuideDash = 3;

/// Whether the configured combination draws anything at all (drives the
/// toolbar toggle's enabled state and the hotkey's no-op).
bool guidesConfigured(GuideLines lines, bool center) =>
    lines != GuideLines.none || center;

/// Whether [rect] is big enough to carry guides at all.
bool guidesFit(Rect rect) =>
    rect.width >= kGuideMinSide && rect.height >= kGuideMinSide;

/// The guide LINE segments (start, end) to draw inside [rect]: the rule-of-
/// thirds grid or the corner diagonals per [lines]. Empty for `none` or a
/// too-small rect. The center mark is separate: see [guideCenterMark].
List<(Offset, Offset)> guideSegments(Rect rect, {required GuideLines lines}) {
  final out = <(Offset, Offset)>[];
  if (!guidesFit(rect)) return out;
  switch (lines) {
    case GuideLines.none:
      break;
    case GuideLines.grid:
      final x1 = rect.left + rect.width / 3;
      final x2 = rect.left + rect.width * 2 / 3;
      final y1 = rect.top + rect.height / 3;
      final y2 = rect.top + rect.height * 2 / 3;
      out
        ..add((Offset(x1, rect.top), Offset(x1, rect.bottom)))
        ..add((Offset(x2, rect.top), Offset(x2, rect.bottom)))
        ..add((Offset(rect.left, y1), Offset(rect.right, y1)))
        ..add((Offset(rect.left, y2), Offset(rect.right, y2)));
    case GuideLines.diagonals:
      out
        ..add((rect.topLeft, rect.bottomRight))
        ..add((rect.topRight, rect.bottomLeft));
  }
  return out;
}

/// The center-mark plus (two segments of [kGuideCenterArm] half-length) for
/// [rect], or empty when [center] is off or the rect is too small.
List<(Offset, Offset)> guideCenterMark(Rect rect, {required bool center}) {
  if (!center || !guidesFit(rect)) return const [];
  final c = rect.center;
  return [
    (
      Offset(c.dx - kGuideCenterArm, c.dy),
      Offset(c.dx + kGuideCenterArm, c.dy),
    ),
    (
      Offset(c.dx, c.dy - kGuideCenterArm),
      Offset(c.dx, c.dy + kGuideCenterArm),
    ),
  ];
}
