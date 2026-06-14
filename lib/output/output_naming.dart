import 'dart:io';
import '../settings/settings.dart';
import 'deliver.dart';
import 'name_tokens.dart';

/// The resolved output directory + filename for one capture or recording.
class CaptureNaming {
  final Directory dir; // save dir / rendered subfolder
  final String fileName; // rendered filename + extension
  const CaptureNaming(this.dir, this.fileName);
}

/// Resolves the output [dir] (save dir / subfolder) and [fileName] for a
/// capture/recording, sharing ONE [NameContext] so `%i` is identical across the
/// filename and subfolder patterns. The persistent counter is read once and
/// advanced (persisted) only when a rendered pattern actually uses `%i`.
///
/// [ext] is the extension without the dot (png/jpg/mp4/gif). [settings] defaults
/// to [Settings.instance]; the recording controller passes its own instance.
Future<CaptureNaming> resolveCaptureNaming({
  required CaptureSettings cap,
  required String ext,
  String? windowTitle,
  String? appName,
  DateTime? now,
  Settings? settings,
}) async {
  final s = settings ?? Settings.instance;
  final used = patternUsesCounter(cap.filenameTemplate) ||
      patternUsesCounter(cap.subfolderPattern);
  final counter = await s.getNameCounter();
  if (used) await s.setNameCounter(counter + 1);
  final ctx = NameContext(
    now: now ?? DateTime.now(),
    windowTitle: windowTitle ?? '',
    appName: appName ?? '',
    counter: counter,
  );
  final dir = effectiveOutputDir(cap.saveDir, cap.subfolderPattern, ctx);
  final stem = renderPattern(cap.filenameTemplate, ctx, NameMode.filename);
  return CaptureNaming(dir, '$stem.$ext');
}
