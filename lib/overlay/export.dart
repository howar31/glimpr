import 'dart:ui' as ui;
import 'dart:ui' show Rect, Size;
import '../capture/captured_display.dart';
import '../editor/composite.dart';
import '../editor/drawable.dart';
import '../output/deliver.dart';

/// Composites [frozenImage] (native pixels) + [drawables] (logical coords),
/// crops to [selectionLogical] (null = whole display), encodes ONCE, then
/// delivers (file + clipboard + sound — Phase-1b `deliverCapture`). Off the
/// freeze path: compositing + encoding happen here, on commit.
Future<DeliveryResult> exportAnnotated({
  required CapturedDisplay display,
  required ui.Image frozenImage,
  required List<Drawable> drawables,
  required Rect? selectionLogical,
}) async {
  final png = await compositeAndCrop(
    frozen: frozenImage,
    drawables: drawables,
    scaleFactor: display.scaleFactor,
    logicalSize: Size(display.width, display.height),
    selectionLogical: selectionLogical,
  );
  return deliverCapture(pngBytes: png);
}
