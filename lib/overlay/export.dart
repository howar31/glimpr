import 'dart:ui' as ui;
import 'dart:ui' show Rect, Size;
import '../capture/captured_display.dart';
import '../editor/composite.dart';
import '../editor/drawable.dart';
import '../output/deliver.dart';
import '../settings/settings.dart';

/// Composites [frozenImage] (native pixels) + [drawables] (logical coords),
/// crops to [selectionLogical] (null = whole display), encodes ONCE, then
/// delivers (file + clipboard + sound — Phase-1b `deliverCapture`). The save
/// folder comes from Settings (null -> deliverCapture's ~/Pictures/Glimpr
/// default). Off the freeze path: compositing + encoding happen here, on commit.
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
  final saveDir = resolveSaveDir(await Settings.instance.getSaveDirectory());
  // Sounds are orchestrated by the caller (shutter at commit, completion on
  // success), so suppress deliverCapture's built-in shutter leg here.
  return deliverCapture(
    pngBytes: png,
    saveDir: saveDir,
    soundFn: () async {},
  );
}
