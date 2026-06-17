import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Offset, Rect, Size;
import '../capture/captured_display.dart' show SnapWindow;
import '../capture/element_snap.dart';
import 'loupe_config.dart' show LoupeInfoMode;

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

  /// The OS mouse-pointer image (native px, alpha) for the toggleable cursor
  /// layer, or null when there is none (image editor; non-system cursor).
  ui.Image? get cursorImage => null;

  /// The cursor image's display-local LOGICAL top-left, or null when no cursor.
  Offset? get cursorTopLeft => null;

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

  /// Optional LIVE Accessibility element snap. Non-null ONLY on the screenshot
  /// overlay when the Advanced "precise element snap" setting is on AND the AX
  /// permission is granted; null everywhere else (image editor, recording
  /// live-select, AX off) — callers then use [snapWindows] only. [walk]: 0 at
  /// the point, +N up the AX ancestry, -N down toward the point. Returns null on
  /// timeout / no element so the caller falls back to the window snap.
  Future<ElementSnap?> Function(Offset displayLocalPoint, {int walk})?
      get elementSnapAt => null;

  /// Cross-display active signal (overlay: native poll; editor: constant).
  ValueListenable<({int id, Offset cursor})> get activeSignal;

  /// Native cursor control (overlay: bridge; editor: no-op).
  EditorCursorController get cursor;

  /// Right-click exits (overlay: setting; editor: configured by the host).
  bool get rightClickExits;

  /// Whether EditorCore renders its own floating/draggable toolbar over the
  /// canvas (overlay) or the host docks the toolbar itself (image editor).
  bool get showFloatingToolbar;

  /// Whether EditorCore drives a zoom/pan viewport (image editor) or stays at
  /// identity 1:1 (capture overlay).
  bool get viewportInteractive;

  /// Whether the crop tool destructively trims the canvas (image editor) instead
  /// of committing an export-region (capture overlay). When true, a crop drag
  /// leaves a pending selection that Enter / on-canvas ✔ confirms.
  bool get cropTrims;

  /// Live-select (recording) mode: the base image is a transparent stub over
  /// the LIVE screen, the loupe samples live pixels via [liveLoupeSample],
  /// and only the region-selection (crop) tool applies.
  bool get liveSelect => false;

  /// Live loupe pixels: a span×span RGBA8888 patch centered on the NATIVE
  /// pixel (x, y), or null before the live stream delivers a frame. Non-null
  /// only in [liveSelect] mode.
  Future<Uint8List?> Function(int x, int y, int span)? get liveLoupeSample =>
      null;

  /// Commit the current selection/region (overlay: export screenshot; editor:
  /// trim/complete — supplied in later plans).
  Future<void> onExport(Rect? selectionLogical, SnapWindow? window);

  /// Dismiss/close (overlay: hide overlay; editor: close window).
  void onCancel();

  /// Open the Settings window (⌘,). The overlay must dismiss the capture first
  /// (it sits above normal windows); the image editor reveals it directly.
  void openSettings();

  /// Persist the loupe info-display choice after the `?`/`/` cycle so it survives
  /// relaunch. Default no-op; the capture overlay and image editor write it to
  /// Settings (seeded back via [LoupeConfig.infoMode] on the next session).
  void persistLoupeInfoMode(LoupeInfoMode mode) {}
}
