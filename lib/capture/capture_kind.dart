/// Which capture scenario produced an export — gates the opt-in decoration
/// per scenario.
enum CaptureKind {
  overlaySnap, // overlay snap-to-window
  overlayCrop, // overlay freehand crop rect
  overlayWholeDisplay, // overlay drawing-tool whole-display export (never decorated)
  focusedWindow, // direct capture focused window (Cmd+Opt+2)
  display, // direct capture display (Cmd+Opt+3)
  lastRegion, // direct capture last region (Cmd+Opt+4)
}

/// Classify an overlay export. A SNAP commits the window's OWN rect as the
/// selection ([selectionIsWindowRect] — the selection equals the window bounds);
/// a freehand CROP has its own dragged selection (a window may still be present,
/// passed only for the filename token, so it is NOT a snap); neither selection =>
/// the whole annotated display.
CaptureKind overlayCaptureKind({
  required bool selectionIsWindowRect,
  required bool hasSelection,
}) => selectionIsWindowRect
    ? CaptureKind.overlaySnap
    : hasSelection
    ? CaptureKind.overlayCrop
    : CaptureKind.overlayWholeDisplay;
