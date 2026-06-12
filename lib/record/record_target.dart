import 'dart:ui' show Rect;
import '../capture/captured_display.dart' show SnapWindow;

/// Resolve a live-select confirm into a recording target, mirroring the
/// screenshot overlay's own discrimination (overlayCaptureKind): the [window]
/// argument of onExport is merely "the window under the cursor" (it names the
/// file); a SNAP click is recognized by the selection being the window's OWN
/// rect. A drag therefore records its REGION (rect wins), a snap click
/// records the WINDOW (the stream follows it; no windowId degrades to its
/// fixed rect), and no selection records the whole display.
({Rect? rect, int? windowId}) recordTargetFromSelection(
    Rect? selectionLogical, SnapWindow? window) {
  final isSnap = window != null && selectionLogical == window.rect;
  final windowId = isSnap ? window.windowId : null;
  return (
    rect: windowId != null ? null : selectionLogical,
    windowId: windowId,
  );
}
