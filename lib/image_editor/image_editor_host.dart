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
class ImageEditorHost implements EditorHost {
  final ui.Image image;
  final Uint8List bytes;
  final Size fittedSize;
  final Future<void> Function() onComplete;
  final VoidCallback? onClose;

  ImageEditorHost({
    required this.image,
    required this.bytes,
    required this.fittedSize,
    required this.onComplete,
    this.onClose,
  });

  static const int _hostId = 0;
  final ValueNotifier<({int id, Offset cursor})> _active =
      ValueNotifier((id: _hostId, cursor: Offset.zero));

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
  int get hostId => _hostId;
  @override
  Offset get globalOrigin => Offset.zero;
  @override
  List<SnapWindow> get snapWindows => const [];
  @override
  ValueListenable<({int id, Offset cursor})> get activeSignal => _active;
  @override
  EditorCursorController get cursor => const NoopCursorController();
  @override
  bool get rightClickExits => false;
  @override
  Future<void> onExport(Rect? selectionLogical, SnapWindow? window) => onComplete();
  @override
  void onCancel() => onClose?.call();
}
