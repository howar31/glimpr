import 'dart:io';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:pasteboard/pasteboard.dart';
import 'filename.dart';
import 'saver.dart';

/// Outcome of delivering one captured image to its destinations. Each leg runs
/// independently, so a partial failure (e.g. clipboard works but the file save
/// fails) is reported rather than masked (design §11).
class DeliveryResult {
  final String? savedPath; // non-null when the file save succeeded
  final bool copiedToClipboard;
  final bool soundPlayed;
  final Map<String, String> errors; // leg name -> error message

  const DeliveryResult({
    this.savedPath,
    required this.copiedToClipboard,
    required this.soundPlayed,
    this.errors = const {},
  });

  bool get savedOk => savedPath != null;
}

/// Function seams so the orchestration is testable without the real plugins.
typedef SaveFn =
    Future<String> Function(Uint8List bytes, Directory dir, String name);
typedef ClipboardFn = Future<void> Function(Uint8List bytes);
typedef SoundFn = Future<void> Function();

final AudioPlayer _shutterPlayer = AudioPlayer()
  ..setReleaseMode(ReleaseMode.stop);

Future<void> _defaultSound() =>
    _shutterPlayer.play(AssetSource('sounds/shutter.wav'));

/// Delivers an already-encoded image: file save + clipboard write + shutter
/// sound. The bytes are encoded ONCE by the caller and reused for both the file
/// and the clipboard (design §11 — no double compression). The three legs are
/// independent; each captures its own failure into [DeliveryResult.errors].
Future<DeliveryResult> deliverCapture({
  required Uint8List pngBytes,
  Directory? saveDir,
  String? fileName,
  SaveFn? saveFn,
  ClipboardFn? clipboardFn,
  SoundFn? soundFn,
}) async {
  final dir =
      saveDir ?? Directory('${Platform.environment['HOME']}/Pictures/Glimpr');
  final name = fileName ?? screenshotFilename(DateTime.now(), 'png');
  final save =
      saveFn ?? ((b, d, n) => saveBytes(dir: d, fileName: n, bytes: b));
  final clip = clipboardFn ?? Pasteboard.writeImage;
  final sound = soundFn ?? _defaultSound;

  final errors = <String, String>{};

  String? savedPath;
  try {
    savedPath = await save(pngBytes, dir, name);
  } catch (e) {
    errors['save'] = '$e';
  }

  var copied = false;
  try {
    await clip(pngBytes);
    copied = true;
  } catch (e) {
    errors['clipboard'] = '$e';
  }

  var played = false;
  try {
    await sound();
    played = true;
  } catch (e) {
    errors['sound'] = '$e';
  }

  return DeliveryResult(
    savedPath: savedPath,
    copiedToClipboard: copied,
    soundPlayed: played,
    errors: errors,
  );
}
