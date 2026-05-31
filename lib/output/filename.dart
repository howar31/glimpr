String _pad2(int n) => n.toString().padLeft(2, '0');
String _pad4(int n) => n.toString().padLeft(4, '0');

/// Fixed, locale-independent screenshot filename:
/// `Screenshot_YYYY-MM-DD_HH-mm-ss.ext`
String screenshotFilename(DateTime t, String ext) =>
    'Screenshot_${_pad4(t.year)}-${_pad2(t.month)}-${_pad2(t.day)}_'
    '${_pad2(t.hour)}-${_pad2(t.minute)}-${_pad2(t.second)}.$ext';

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
