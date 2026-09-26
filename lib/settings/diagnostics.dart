import 'package:flutter/services.dart';

/// Bug-report environment snapshot: the app/OS/display facts a report needs
/// so the first reply never has to ask for them. Collected ONLY when the
/// report page opens (one `diagnostics` call on the role channel + a handful
/// of settings reads); nothing runs in the background.
///
/// [native] is the role channel's `diagnostics` reply: `os`, `arch`,
/// optional `cpu` / `gpus`, and `displays` (a list of maps whose `name`,
/// `width`, `height`, `scale`, `primary` form the fixed prefix; every other
/// key renders as `key=value`, sorted, so both native sides print alike and
/// can add fields without a Dart change). Null = the channel failed.
String formatDiagnostics({
  required String appVersion,
  required bool isDev,
  required String platformName,
  required String locale,
  required Map<String, Object?>? native,
  required Map<String, String> settings,
}) {
  final lines = <String>[];
  final arch = native?['arch'];
  final archPart = arch is String && arch.isNotEmpty ? ' $arch' : '';
  lines.add('Glimpr $appVersion${isDev ? ' dev' : ''}, $platformName$archPart');
  if (native == null) {
    lines.add('Native diagnostics unavailable');
  } else {
    final os = native['os'];
    if (os is String && os.isNotEmpty) lines.add('OS: $os');
    final cpu = native['cpu'];
    if (cpu is String && cpu.isNotEmpty) lines.add('CPU: $cpu');
    final gpus = native['gpus'];
    if (gpus is List && gpus.isNotEmpty) {
      lines.add('GPU: ${gpus.map((g) => '$g').join('; ')}');
    }
  }
  lines.add('Locale: $locale');
  if (settings.isNotEmpty) {
    lines.add('Settings: '
        '${settings.entries.map((e) => '${e.key}=${e.value}').join(', ')}');
  }
  final displays = native?['displays'];
  if (displays is List) {
    for (var i = 0; i < displays.length; i++) {
      final d = displays[i];
      if (d is! Map) continue;
      lines.add(_displayLine(i + 1, d, windowsScale: platformName == 'Windows'));
    }
  }
  return lines.join('\n');
}

const _kDisplayPrefixKeys = {'name', 'width', 'height', 'scale', 'primary'};

String _displayLine(int index, Map d, {required bool windowsScale}) {
  final primary = d['primary'] == true ? ' (primary)' : '';
  final name = d['name'] ?? '?';
  final scale = d['scale'];
  final scaleText = scale is num
      ? (windowsScale
          ? '@${(scale * 100).round()}%'
          : '@${scale == scale.roundToDouble() ? scale.toInt() : scale}x')
      : '';
  final b = StringBuffer(
      'Display $index$primary: $name, ${d['width']}x${d['height']}');
  if (scaleText.isNotEmpty) b.write(' $scaleText');
  final rest = d.keys
      .map((k) => '$k')
      .where((k) => !_kDisplayPrefixKeys.contains(k))
      .toList()
    ..sort();
  for (final k in rest) {
    b.write(', $k=${d[k]}');
  }
  return b.toString();
}

/// The native side's `diagnostics` reply as a string-keyed map, or null when
/// the channel is absent (tests) or fails (never blocks the page).
Future<Map<String, Object?>?> fetchNativeDiagnostics(
    MethodChannel channel) async {
  try {
    final r = await channel.invokeMethod<Object?>('diagnostics');
    if (r is! Map) return null;
    return r.map((k, v) => MapEntry('$k', _normalize(v)));
  } catch (_) {
    return null;
  }
}

// Channel maps arrive as Map<Object?, Object?>; re-key nested maps/lists so
// callers can read them as Map<String, Object?>.
Object? _normalize(Object? v) {
  if (v is Map) return v.map((k, x) => MapEntry('$k', _normalize(x)));
  if (v is List) return v.map(_normalize).toList();
  return v;
}
