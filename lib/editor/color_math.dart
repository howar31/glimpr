import 'dart:ui';

/// Parse `#RRGGBB`, `#AARRGGBB` (leading # optional, case-insensitive).
/// 6-digit is treated as fully opaque. Returns null on any invalid input.
Color? hexToColor(String input) {
  var h = input.trim();
  if (h.startsWith('#')) h = h.substring(1);
  if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(h)) return null;
  if (h.length == 6) h = 'FF$h';
  if (h.length != 8) return null;
  return Color(int.parse(h, radix: 16));
}

/// Format as `#AARRGGBB` (default) or `#RRGGBB` when [withAlpha] is false.
String colorToHex(Color c, {bool withAlpha = true}) {
  final argb = c.toARGB32();
  final s = argb.toRadixString(16).padLeft(8, '0').toUpperCase();
  return withAlpha ? '#$s' : '#${s.substring(2)}';
}

/// Most-recently-used list of ARGB ints: re-pushing moves to front, deduped,
/// capped at [cap]. Returns a new list (does not mutate the input).
List<int> pushRecentColor(List<int> recents, int argb, {int cap = 8}) {
  final out = [argb, ...recents.where((c) => c != argb)];
  return out.length > cap ? out.sublist(0, cap) : out;
}
