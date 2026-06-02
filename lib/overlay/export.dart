import 'dart:ui' as ui;
import 'dart:ui' show Rect, Size;
import '../capture/captured_display.dart';
import '../editor/composite.dart';
import '../editor/drawable.dart';
import '../output/deliver.dart';
import '../output/filename.dart';
import '../settings/settings.dart';

/// Composites [frozenImage] (native pixels) + [drawables] (logical coords),
/// crops to [selectionLogical] (null = whole display), encodes ONCE in the
/// format from [cap], then delivers per [cap] (file save + clipboard, each
/// toggleable). The shutter / completion sounds are orchestrated by the caller,
/// so deliverCapture's own sound leg is suppressed here. Off the freeze path:
/// compositing + encoding happen here, on commit.
Future<DeliveryResult> exportAnnotated({
  required CapturedDisplay display,
  required ui.Image frozenImage,
  required List<Drawable> drawables,
  required Rect? selectionLogical,
  required CaptureSettings cap,
}) async {
  final bytes = await compositeAndCrop(
    frozen: frozenImage,
    drawables: drawables,
    scaleFactor: display.scaleFactor,
    logicalSize: Size(display.width, display.height),
    selectionLogical: selectionLogical,
    jpeg: cap.isJpeg,
    jpegQuality: cap.jpegQuality,
  );
  return deliverCapture(
    pngBytes: bytes,
    saveDir: cap.saveDir,
    fileName: screenshotFilename(DateTime.now(), cap.fileExtension),
    soundFn: () async {},
    saveToFile: cap.saveToFile,
    copyToClipboard: cap.copyToClipboard,
  );
}
