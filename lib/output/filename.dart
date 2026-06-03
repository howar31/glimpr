String _pad2(int n) => n.toString().padLeft(2, '0');
String _pad4(int n) => n.toString().padLeft(4, '0');

/// Fixed, locale-independent screenshot filename:
/// `Screenshot_YYYY-MM-DD_HH-mm-ss.ext`. Kept as the built-in fallback.
String screenshotFilename(DateTime t, String ext) =>
    'Screenshot_${_pad4(t.year)}-${_pad2(t.month)}-${_pad2(t.day)}_'
    '${_pad2(t.hour)}-${_pad2(t.minute)}-${_pad2(t.second)}.$ext';

/// Default user-facing filename template (tokens documented in settings).
const defaultFilenameTemplate = '{window}_{date}_{time}';

/// Strip filesystem-reserved characters, collapse whitespace, cap the length —
/// a window title can contain anything ("Inbox (3) — Gmail", paths, slashes).
String _sanitize(String s) {
  s = s.replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1f]'), '');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (s.length > 50) s = s.substring(0, 50).trim();
  return s;
}

/// Tidy the separators an empty token leaves behind (e.g. `{title}` empty in
/// `{title}_{date}`): collapse doubled `_`/spaces and trim separator ends.
String _cleanup(String s) {
  s = s.replaceAll(RegExp(r'__+'), '_');
  s = s.replaceAll(RegExp(r'\s{2,}'), ' ');
  s = s.replaceAll(RegExp(r'^[_\-\s]+|[_\-\s]+$'), '');
  return s.trim();
}

/// Builds a filename from a user [template] with these tokens:
///   {window} the window title, or the app name when the title is unavailable
///   {app}    the owning application name
///   {date}   YYYY-MM-DD
///   {time}   HH-mm-ss
/// Empty window/app tokens are tidied away (no dangling separators); a template
/// that resolves to nothing falls back to the built-in name so a file is never
/// unnamed. [ext] is appended (the template carries no dot).
String buildScreenshotName({
  required String template,
  required DateTime t,
  String? windowTitle,
  String? appName,
  required String ext,
}) {
  final date = '${_pad4(t.year)}-${_pad2(t.month)}-${_pad2(t.day)}';
  final time = '${_pad2(t.hour)}-${_pad2(t.minute)}-${_pad2(t.second)}';
  final title = _sanitize(windowTitle ?? '');
  final app = _sanitize(appName ?? '');
  var s = template
      .replaceAll('{date}', date)
      .replaceAll('{time}', time)
      .replaceAll('{window}', title.isNotEmpty ? title : app)
      .replaceAll('{app}', app);
  s = _cleanup(s);
  if (s.isEmpty) s = 'Screenshot_${date}_$time';
  return '$s.$ext';
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
