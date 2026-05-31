import 'dart:io';
import 'dart:ui' show Rect;
import '../capture/captured_display.dart';
import '../imaging/crop.dart';
import '../output/filename.dart';
import '../output/saver.dart';

/// Crops [display]'s frozen PNG to the display-local logical [selection] and
/// saves a timestamped PNG into [saveDir] (default ~/Pictures/Glimpr). Returns
/// the written path. Off the freeze path: encoding happens here, on commit.
Future<String> exportSelection({
  required CapturedDisplay display,
  required Rect selection,
  Directory? saveDir,
}) async {
  final png = cropToSelection(
    pngBytes: display.pngBytes,
    scaleFactor: display.scaleFactor,
    selection: selection,
  );
  final dir = saveDir ??
      Directory('${Platform.environment['HOME']}/Pictures/Glimpr');
  return saveBytes(
    dir: dir,
    fileName: screenshotFilename(DateTime.now(), 'png'),
    bytes: png,
  );
}
