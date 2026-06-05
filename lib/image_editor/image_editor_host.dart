import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Offset, Rect, Size, VoidCallback;
import '../capture/captured_display.dart' show SnapWindow;
import '../editor/editor_host.dart';

/// [EditorHost] for the standalone Image Editor: a loaded image displayed at a
/// fixed fitted size in a window. Reuses the overlay's (logicalSize + pixelScale
/// + native baseImage) model — [size] is the fitted logical size, [pixelScale]
/// maps it back to the image's native pixels for full-resolution export. No
/// native cursor, no window-snap, no cross-display; always active.
///
/// [activeSignal] must be injected by the caller (typically owned by the parent
/// State) so that the stable notifier survives per-build host reconstruction.
class ImageEditorHost implements EditorHost {
  final ui.Image image;
  final Uint8List bytes;
  final Size fittedSize;
  final Future<void> Function() onComplete;
  final VoidCallback? onClose;
  @override
  final ValueListenable<({int id, Offset cursor})> activeSignal;

  ImageEditorHost({
    required this.image,
    required this.bytes,
    required this.fittedSize,
    required this.onComplete,
    required this.activeSignal,
    this.onClose,
  });

  static const int kImageEditorHostId = 0;

  @override
  Size get size => fittedSize;
  @override
  double get pixelScale => image.width / fittedSize.width;
  @override
  ui.Image get baseImage => image;
  @override
  Uint8List get baseImageBytes => bytes;
  @override
  Offset? get cursorSeed => null; // EditorCore seeds at centre
  @override
  bool get startsActive => true;
  @override
  int get hostId => kImageEditorHostId;
  @override
  Offset get globalOrigin => Offset.zero;
  @override
  List<SnapWindow> get snapWindows => const [];
  @override
  EditorCursorController get cursor => const NoopCursorController();
  @override
  bool get rightClickExits => false;
  @override
  Future<void> onExport(Rect? selectionLogical, SnapWindow? window) => onComplete();
  @override
  void onCancel() => onClose?.call();
}
