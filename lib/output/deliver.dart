import 'dart:io';
import 'dart:typed_data';
import 'clipboard.dart';
import 'filename.dart';
import 'name_tokens.dart';
import 'saver.dart';
import 'sounds.dart';

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

Future<void> _defaultSound() => playShutter();

/// Delivers an already-encoded image (PNG or JPEG): file save + clipboard write
/// + shutter sound. The bytes are encoded ONCE by the caller and reused for both
/// the file and the clipboard (design §11 — no double compression). The legs are
/// independent; each captures its own failure into [DeliveryResult.errors]. The
/// save / clipboard legs can be disabled via [saveToFile] / [copyToClipboard]
/// (a disabled leg is skipped, not failed — its result flag stays false with no
/// error recorded).
/// The effective output folder: the configured save directory, or the default
/// the save leg falls back to. Shared with the gallery's "More…" tile so the
/// folder it opens is exactly where saves land.
Directory effectiveSaveDir(Directory? configured) {
  if (configured != null) return configured;
  // Windows GUI processes do not get HOME (that is a Unix/msys var); use
  // USERPROFILE there. macOS/Linux keep HOME and the '/' separator.
  final home = Platform.isWindows
      ? (Platform.environment['USERPROFILE'] ??
          Platform.environment['HOME'] ??
          '.')
      : (Platform.environment['HOME'] ?? '.');
  return Directory(
      '$home${Platform.pathSeparator}Pictures${Platform.pathSeparator}Glimpr');
}

/// The effective output directory for a capture: [effectiveSaveDir] with the
/// rendered [subfolderPattern] appended as a RELATIVE path. An empty rendered
/// subfolder (or an empty pattern) yields the save dir itself.
Directory effectiveOutputDir(
    Directory? base, String subfolderPattern, NameContext ctx) {
  final root = effectiveSaveDir(base);
  final sub = renderPattern(subfolderPattern, ctx, NameMode.path);
  return sub.isEmpty
      ? root
      : Directory('${root.path}${Platform.pathSeparator}$sub');
}

Future<DeliveryResult> deliverCapture({
  required Uint8List pngBytes,
  Directory? saveDir,
  String? fileName,
  SaveFn? saveFn,
  ClipboardFn? clipboardFn,
  SoundFn? soundFn,
  bool saveToFile = true,
  bool copyToClipboard = true,
}) async {
  final dir = effectiveSaveDir(saveDir);
  final name = fileName ?? screenshotFilename(DateTime.now(), 'png');
  final save =
      saveFn ?? ((b, d, n) => saveBytes(dir: d, fileName: n, bytes: b));
  final clip = clipboardFn ?? clipboardWriteImage;
  final sound = soundFn ?? _defaultSound;

  final errors = <String, String>{};

  String? savedPath;
  if (saveToFile) {
    try {
      savedPath = await save(pngBytes, dir, name);
    } catch (e) {
      errors['save'] = '$e';
    }
  }

  var copied = false;
  if (copyToClipboard) {
    try {
      await clip(pngBytes);
      copied = true;
    } catch (e) {
      errors['clipboard'] = '$e';
    }
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
