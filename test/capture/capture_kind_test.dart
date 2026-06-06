import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/capture/capture_kind.dart';

void main() {
  test('overlayCaptureKind: snap only when the selection IS the window rect', () {
    // Snap: the selection equals the snapped window's rect.
    expect(
      overlayCaptureKind(selectionIsWindowRect: true, hasSelection: true),
      CaptureKind.overlaySnap,
    );
    // Freehand crop: a dragged selection (a window may still ride along only for
    // the filename, so selectionIsWindowRect is false).
    expect(
      overlayCaptureKind(selectionIsWindowRect: false, hasSelection: true),
      CaptureKind.overlayCrop,
    );
    // Whole display (drawing-tool Enter): no selection, even if a window is under
    // the cursor for the filename.
    expect(
      overlayCaptureKind(selectionIsWindowRect: false, hasSelection: false),
      CaptureKind.overlayWholeDisplay,
    );
  });
}
