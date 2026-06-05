import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Offset, Rect, Size, VoidCallback;
import '../capture/capture_bridge.dart';
import '../capture/captured_display.dart';
import '../editor/editor_host.dart';

/// Adapts the native [CaptureBridge] cursor calls to [EditorCursorController].
class OverlayCursorController implements EditorCursorController {
  final CaptureBridge _bridge;
  OverlayCursorController([CaptureBridge? bridge]) : _bridge = bridge ?? CaptureBridge();
  @override
  void setHidden(bool hidden) => _bridge.setCursorHidden(hidden);
  @override
  void setDrawingLock(bool locked) => _bridge.setDrawingLock(locked);
  @override
  void warp(double globalX, double globalY) => _bridge.warpCursor(globalX, globalY);
}

/// [EditorHost] for the per-display capture overlay: a frozen [CapturedDisplay],
/// the cross-display active signal, native cursor control, and the export/cancel
/// callbacks owned by `overlay_app.dart`.
class OverlayEditorHost implements EditorHost {
  final CapturedDisplay display;
  final ui.Image frozen;
  final ValueListenable<({int id, Offset cursor})> _activeSignal;
  final bool _rightClickExits;
  final Future<void> Function(Rect? selectionLogical, SnapWindow? window) _onExport;
  final VoidCallback _onCancel;
  final EditorCursorController _cursor;

  OverlayEditorHost({
    required this.display,
    required this.frozen,
    required this._activeSignal,
    required this._rightClickExits,
    required this._onExport,
    required this._onCancel,
    EditorCursorController? cursor,
  }) : _cursor = cursor ?? OverlayCursorController();

  @override
  Size get size => Size(display.width, display.height);
  @override
  double get pixelScale => display.scaleFactor;
  @override
  ui.Image get baseImage => frozen;
  @override
  Uint8List get baseImageBytes => display.pngBytes;
  @override
  Offset? get cursorSeed => (display.cursorX != null && display.cursorY != null)
      ? Offset(display.cursorX!, display.cursorY!)
      : null;
  @override
  bool get startsActive => display.isCursorDisplay;
  @override
  int get hostId => display.displayId;
  @override
  Offset get globalOrigin => Offset(display.left, display.top);
  @override
  List<SnapWindow> get snapWindows => display.windows;
  @override
  ValueListenable<({int id, Offset cursor})> get activeSignal => _activeSignal;
  @override
  EditorCursorController get cursor => _cursor;
  @override
  bool get rightClickExits => _rightClickExits;
  @override
  bool get showFloatingToolbar => true;
  @override
  bool get viewportInteractive => false;
  @override
  bool get cropTrims => false;
  @override
  Future<void> onExport(Rect? selectionLogical, SnapWindow? window) =>
      _onExport(selectionLogical, window);
  @override
  void onCancel() => _onCancel();
}
