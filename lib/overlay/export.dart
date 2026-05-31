import 'dart:io';
import 'dart:ui' show Rect;
import '../capture/captured_display.dart';
import '../imaging/crop.dart';
import '../output/deliver.dart';

/// Crops [display]'s frozen PNG to the display-local logical [selection], then
/// delivers it: save to [saveDir] (default ~/Pictures/Glimpr), copy to the
/// clipboard, and play the shutter sound. Encoding happens ONCE here (off the
/// freeze path) and the same bytes feed both file and clipboard. Returns the
/// per-leg [DeliveryResult].
Future<DeliveryResult> exportSelection({
  required CapturedDisplay display,
  required Rect selection,
  Directory? saveDir,
  SaveFn? saveFn,
  ClipboardFn? clipboardFn,
  SoundFn? soundFn,
}) async {
  final png = cropToSelection(
    pngBytes: display.pngBytes,
    scaleFactor: display.scaleFactor,
    selection: selection,
  );
  return deliverCapture(
    pngBytes: png,
    saveDir: saveDir,
    saveFn: saveFn,
    clipboardFn: clipboardFn,
    soundFn: soundFn,
  );
}
