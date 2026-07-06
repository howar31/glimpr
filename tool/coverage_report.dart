// Aggregates coverage/lcov.info into a per-area table.
//
// Usage:
//   flutter test --coverage
//   dart run tool/coverage_report.dart [--files]
//
// Generated localizations (lib/l10n/gen/) are excluded from the totals so the
// headline number tracks hand-written code. --files adds a per-file listing
// (worst first) under each area.

import 'dart:io';

void main(List<String> args) {
  final showFiles = args.contains('--files');
  final lcov = File('coverage/lcov.info');
  if (!lcov.existsSync()) {
    stderr.writeln('coverage/lcov.info not found; run: flutter test --coverage');
    exitCode = 1;
    return;
  }

  // path -> (hit, found)
  final records = <String, (int, int)>{};
  String? path;
  var found = 0, hit = 0;
  for (final raw in lcov.readAsLinesSync()) {
    final line = raw.trim();
    if (line.startsWith('SF:')) {
      path = line.substring(3);
      found = 0;
      hit = 0;
    } else if (line.startsWith('LF:')) {
      found = int.parse(line.substring(3));
    } else if (line.startsWith('LH:')) {
      hit = int.parse(line.substring(3));
    } else if (line == 'end_of_record' && path != null) {
      records[path] = (hit, found);
      path = null;
    }
  }

  String rel(String p) {
    final root = Directory.current.path;
    var r = p.startsWith(root) ? p.substring(root.length + 1) : p;
    if (r.startsWith('lib/')) r = r.substring(4);
    return r;
  }

  final included = <String, (int, int)>{
    for (final e in records.entries)
      if (!e.key.contains('/l10n/gen/')) rel(e.key): e.value,
  };
  final excludedCount = records.length - included.length;

  // Aggregate by top-level area under lib/.
  final areas = <String, List<(String, int, int)>>{};
  for (final e in included.entries) {
    final slash = e.key.indexOf('/');
    final area = slash < 0 ? '(root)' : e.key.substring(0, slash);
    (areas[area] ??= []).add((e.key, e.value.$1, e.value.$2));
  }

  var totalHit = 0, totalFound = 0;
  for (final v in included.values) {
    totalHit += v.$1;
    totalFound += v.$2;
  }

  String pct(int h, int f) =>
      f == 0 ? '  n/a' : '${(100 * h / f).toStringAsFixed(1).padLeft(5)}%';

  final names = areas.keys.toList()
    ..sort((a, b) {
      int f(String k) =>
          areas[k]!.fold(0, (s, r) => s + r.$3);
      return f(b).compareTo(f(a));
    });
  stdout.writeln('Area coverage (lib/l10n/gen excluded, $excludedCount generated files skipped):');
  for (final name in names) {
    final rows = areas[name]!;
    var h = 0, f = 0;
    for (final r in rows) {
      h += r.$2;
      f += r.$3;
    }
    stdout.writeln('  ${name.padRight(16)} ${pct(h, f)}  ($h/$f, ${rows.length} files)');
    if (showFiles) {
      rows.sort((a, b) => (a.$2 / (a.$3 == 0 ? 1 : a.$3))
          .compareTo(b.$2 / (b.$3 == 0 ? 1 : b.$3)));
      for (final r in rows) {
        stdout.writeln('      ${pct(r.$2, r.$3)}  ${r.$2}/${r.$3}  ${r.$1}');
      }
    }
  }
  stdout.writeln('  ${'TOTAL'.padRight(16)} ${pct(totalHit, totalFound)}  '
      '($totalHit/$totalFound, ${included.length} files)');
}
