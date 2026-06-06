import 'dart:convert';
import '../settings/settings_store.dart';
import 'color_math.dart';
import 'draw_style.dart';
import 'editor_controller.dart';

const _kStylesKey = 'tool_styles';
const _kRecentsKey = 'recent_colors';
const int kRecentColorsCap = 14; // two rows of 7 in the picker

/// Persists `Map<ToolKind, DrawStyle>` as one JSON object keyed by ToolKind.name,
/// plus a global recent-colours MRU list. Same single-key pattern as
/// ShortcutStore / LastRegionStore; cross-engine via the shared NSUserDefaults.
class ToolStyleStore {
  ToolStyleStore(this.store);
  final SettingsStore store;

  Future<Map<ToolKind, DrawStyle>> load() async {
    final s = await store.getString(_kStylesKey);
    if (s == null || s.isEmpty) return {};
    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(s) as Map<String, dynamic>;
    } catch (_) {
      return {}; // corrupt -> defaults
    }
    final out = <ToolKind, DrawStyle>{};
    for (final entry in decoded.entries) {
      final kind = ToolKind.values.where((k) => k.name == entry.key);
      if (kind.isEmpty) continue; // unknown tool name -> skip
      try {
        out[kind.first] =
            DrawStyle.fromJson(entry.value as Map<String, dynamic>);
      } catch (_) {/* skip a single corrupt entry */}
    }
    return out;
  }

  Future<void> save(Map<ToolKind, DrawStyle> styles) async {
    final encoded = <String, dynamic>{};
    styles.forEach((k, v) => encoded[k.name] = v.toJson());
    await store.setString(_kStylesKey, jsonEncode(encoded));
  }

  Future<void> resetAll() => store.remove(_kStylesKey);

  Future<List<int>> loadRecentColors() async {
    final s = await store.getString(_kRecentsKey);
    if (s == null || s.isEmpty) return [];
    try {
      return (jsonDecode(s) as List).map((e) => (e as num).toInt()).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> pushRecentColor(int argb) async {
    final next = pushRecentColor0(await loadRecentColors(), argb);
    await store.setString(_kRecentsKey, jsonEncode(next));
  }
}

// Thin alias so the pure helper (color_math.pushRecentColor) and the async
// store method don't collide on name.
List<int> pushRecentColor0(List<int> recents, int argb) =>
    pushRecentColor(recents, argb, cap: kRecentColorsCap);
