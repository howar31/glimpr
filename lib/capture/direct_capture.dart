import 'dart:ui' show Rect;
import 'captured_display.dart';
import 'last_region.dart';

/// What a direct capture should output: a [display] frame, an optional crop
/// [selectionLogical] (null = whole display), and an optional window name for
/// the filename token.
class CaptureTarget {
  const CaptureTarget({
    required this.display,
    this.selectionLogical,
    this.windowTitle,
    this.appName,
  });
  final CapturedDisplay display;
  final Rect? selectionLogical;
  final String? windowTitle;
  final String? appName;
}

/// The display under the cursor (whole display). Null when no frames.
CaptureTarget? resolveScreenTarget(List<CapturedDisplay> frames) {
  if (frames.isEmpty) return null;
  final d = frames.firstWhere((f) => f.isCursorDisplay, orElse: () => frames.first);
  return CaptureTarget(display: d);
}

/// The focused window's rect on its display. Falls back to [resolveScreenTarget]
/// when there is no focused window or its display was not captured.
CaptureTarget? resolveWindowTarget(
    List<CapturedDisplay> frames, FocusedWindowInfo? window) {
  if (window == null) return resolveScreenTarget(frames);
  for (final f in frames) {
    if (f.displayId == window.displayId) {
      return CaptureTarget(
        display: f,
        selectionLogical: window.rect,
        windowTitle: window.title,
        appName: window.app,
      );
    }
  }
  return resolveScreenTarget(frames);
}

/// The stored region's rect on its display. Null (no-op) when nothing is stored
/// or the stored display is no longer present.
CaptureTarget? resolveLastRegionTarget(
    List<CapturedDisplay> frames, LastRegion? region) {
  if (region == null) return null;
  for (final f in frames) {
    if (f.displayId == region.displayId) {
      return CaptureTarget(display: f, selectionLogical: region.rect);
    }
  }
  return null;
}
