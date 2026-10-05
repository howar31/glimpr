import 'dart:typed_data';

/// One application, as shown in the Privacy pane. [id] is the platform
/// identifier the native capture code matches on: a bundle id on macOS, a
/// lower-cased exe path with forward slashes on Windows.
class ExcludedApp {
  const ExcludedApp({required this.id, required this.name, this.icon});

  final String id;
  final String name;

  /// PNG bytes, or null when the app could not be resolved.
  final Uint8List? icon;

  static ExcludedApp? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    final name = raw['name'];
    final icon = raw['icon'];
    return ExcludedApp(
      id: id,
      name: (name is String && name.isNotEmpty) ? name : id,
      icon: icon is Uint8List && icon.isNotEmpty ? icon : null,
    );
  }
}

/// How one excluded application is treated. The set is platform-shaped:
/// macOS chooses WHERE the application is left out ([all] / [screenshots] /
/// [recordings]); Windows chooses HOW its windows are covered in screenshots
/// ([all] = black, [blur]).
enum ExcludeMode {
  all(''),
  screenshots('shot'),
  recordings('rec'),
  blur('blur');

  const ExcludeMode(this.wire);

  /// The suffix stored after the id; empty for the default.
  final String wire;

  static ExcludeMode fromWire(String wire) => values.firstWhere(
        (m) => m.wire == wire,
        orElse: () => ExcludeMode.all,
      );
}

/// One stored entry of the excluded list.
class ExcludedEntry {
  const ExcludedEntry(this.id, [this.mode = ExcludeMode.all]);
  final String id;
  final ExcludeMode mode;

  @override
  bool operator ==(Object other) =>
      other is ExcludedEntry && other.id == id && other.mode == mode;

  @override
  int get hashCode => Object.hash(id, mode);

  @override
  String toString() => 'ExcludedEntry($id, ${mode.name})';
}

/// The stored form of the list: entries joined by `|`, each an id with an
/// optional `?mode` suffix. Neither character can occur in a bundle id or a
/// Windows path. The native side reads this string directly.
List<ExcludedEntry> decodeExcludedApps(String? raw) {
  if (raw == null || raw.isEmpty) return const [];
  final out = <ExcludedEntry>[];
  for (final part in raw.split('|')) {
    final cut = part.indexOf('?');
    final id = (cut < 0 ? part : part.substring(0, cut)).trim();
    if (id.isEmpty || out.any((e) => e.id == id)) continue;
    final mode = cut < 0
        ? ExcludeMode.all
        : ExcludeMode.fromWire(part.substring(cut + 1).trim());
    out.add(ExcludedEntry(id, mode));
  }
  return out;
}

String encodeExcludedApps(Iterable<ExcludedEntry> entries) {
  final seen = <String>{};
  final out = <String>[];
  for (final e in entries) {
    final id = e.id.replaceAll(RegExp(r'[|?]'), '').trim();
    if (id.isEmpty || !seen.add(id)) continue;
    out.add(e.mode == ExcludeMode.all ? id : '$id?${e.mode.wire}');
  }
  return out.join('|');
}
