import 'name_tokens.dart';

String _pad2(int n) => n.toString().padLeft(2, '0');
String _pad4(int n) => n.toString().padLeft(4, '0');

/// Fixed, locale-independent screenshot filename:
/// `Screenshot_YYYY-MM-DD_HH-mm-ss.ext`. Kept as the built-in fallback.
String screenshotFilename(DateTime t, String ext) =>
    'Screenshot_${_pad4(t.year)}-${_pad2(t.month)}-${_pad2(t.day)}_'
    '${_pad2(t.hour)}-${_pad2(t.minute)}-${_pad2(t.second)}.$ext';

/// Default user-facing filename template (strftime `%`-tokens; see
/// [kNameTokens]). Renders e.g. `Safari_2026-06-14_22-30-05`.
const defaultFilenameTemplate = '%title_%Y-%m-%d_%H-%M-%S';

/// Default output subfolder pattern (date folders, three levels). Renders e.g.
/// `2026/2026-06/2026-06-14`. Shared by screenshot + recording.
const defaultSubfolderPattern = '%Y/%Y-%m/%Y-%m-%d';

/// Builds a filename from a user [template] of `%`-tokens (see [kNameTokens]),
/// appending `.[ext]`. Path separators and reserved characters are stripped;
/// a template that resolves to nothing falls back to the built-in name so a
/// file is never unnamed. [counter] feeds `%i`; [rand] is injectable for tests.
String buildScreenshotName({
  required String template,
  required DateTime t,
  String? windowTitle,
  String? appName,
  required String ext,
  int counter = 0,
  int Function(int n)? rand,
}) {
  final ctx = NameContext(
    now: t,
    windowTitle: windowTitle ?? '',
    appName: appName ?? '',
    counter: counter,
    rand: rand,
  );
  final stem = renderPattern(template, ctx, NameMode.filename);
  return '$stem.$ext';
}

/// Returns [baseName] if free, else inserts a _NNN counter before the extension.
String uniqueName(String baseName, {required bool Function(String) exists}) {
  if (!exists(baseName)) return baseName;
  final dot = baseName.lastIndexOf('.');
  final stem = dot == -1 ? baseName : baseName.substring(0, dot);
  final ext = dot == -1 ? '' : baseName.substring(dot);
  for (var i = 1; i < 1000; i++) {
    final candidate = '${stem}_${_pad4(i).substring(1)}$ext';
    if (!exists(candidate)) return candidate;
  }
  throw StateError('too many same-second collisions for $baseName');
}
