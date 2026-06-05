import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Offset, Rect, Size;
import '../capture/captured_display.dart' show SnapWindow;

/// Native cursor control EditorCore needs. The overlay implements this with the
/// native capture bridge; the image editor uses [NoopCursorController].
abstract class EditorCursorController {
  void setHidden(bool hidden);
  void setDrawingLock(bool locked);

  /// Warp the OS cursor to a GLOBAL desktop point (logical points, top-left
  /// origin). Used by the region-tool arrow-nudge.
  void warp(double globalX, double globalY);
}

/// A cursor controller that does nothing — for hosts with no native cursor
/// management (the standalone image editor window).
class NoopCursorController implements EditorCursorController {
  const NoopCursorController();
  @override
  void setHidden(bool hidden) {}
  @override
  void setDrawingLock(bool locked) {}
  @override
  void warp(double globalX, double globalY) {}
}

/// Everything a host (capture overlay or standalone image editor) supplies to
/// [EditorCore]. The overlay adapter wraps a CapturedDisplay + CaptureBridge +
/// the cross-display active signal; the image-editor adapter supplies a loaded
/// file, a no-op cursor, and a constant always-active signal.
abstract class EditorHost {
  /// Logical canvas size (display size for the overlay; image logical size for
  /// the editor).
  Size get size;

  /// Native:logical pixel ratio (display scaleFactor; 1.0 for a loaded file).
  double get pixelScale;

  /// Base image at native pixels (frozen frame / loaded image) — loupe + raster.
  ui.Image get baseImage;

  /// Encoded bytes for the cheap on-screen `Image.memory` layer.
  Uint8List get baseImageBytes;

  /// Crosshair seed on first build (cursor display-local point), or null = centre.
  Offset? get cursorSeed;

  /// Whether this host starts active (overlay: isCursorDisplay; editor: true).
  bool get startsActive;

  /// Identifier matched against [activeSignal].id (overlay: displayId).
  int get hostId;

  /// Global desktop origin of this canvas (overlay: display.left/top; editor: 0).
  Offset get globalOrigin;

  /// Snappable windows (overlay: capture-time list; editor: empty).
  List<SnapWindow> get snapWindows;

  /// Cross-display active signal (overlay: native poll; editor: constant).
  ValueListenable<({int id, Offset cursor})> get activeSignal;

  /// Native cursor control (overlay: bridge; editor: no-op).
  EditorCursorController get cursor;

  /// Right-click exits (overlay: setting; editor: configured by the host).
  bool get rightClickExits;

  /// Commit the current selection/region (overlay: export screenshot; editor:
  /// trim/complete — supplied in later plans).
  Future<void> onExport(Rect? selectionLogical, SnapWindow? window);

  /// Dismiss/close (overlay: hide overlay; editor: close window).
  void onCancel();
}
