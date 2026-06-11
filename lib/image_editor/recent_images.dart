import 'dart:convert';
import '../settings/settings_store.dart';

/// Default cap on the recent-images list: a multiple of the gallery's
/// min-window column count (5) MINUS ONE, so the trailing "More…" utility
/// tile completes the rectangle at the smallest window (owner design,
/// 2026-06-11). The landing gallery scrolls past what fits, so the cap is
/// about history depth (and prune cost), not screen space.
const int kRecentImagesCap = 44;

/// Move-to-front dedup: [added] becomes the head, any prior occurrence removed,
/// then the list is capped to [cap] (oldest dropped). Pure so it is unit-tested
/// without a store.
List<String> mergeRecent(List<String> existing, String added,
    {int cap = kRecentImagesCap}) {
  final out = <String>[added, ...existing.where((p) => p != added)];
  return out.length > cap ? out.sublist(0, cap) : out;
}

/// Drop [removed] from the list, keeping the remaining order. Pure for tests.
List<String> removeRecent(List<String> existing, String removed) =>
    existing.where((p) => p != removed).toList();

/// Drop paths whose file is gone (the [exists] predicate is injected so this is
/// testable without touching the filesystem).
List<String> pruneMissing(List<String> paths, bool Function(String) exists) =>
    paths.where(exists).toList();

/// Persists the recently-opened image paths as a JSON list in the shared settings
/// store (NSUserDefaults), newest first, capped at [kRecentImagesCap]. Mirrors
/// [LastRegionStore]: written by the image-editor engine, survives a restart.
class RecentImagesStore {
  RecentImagesStore(this.store);
  final SettingsStore store;
  static const _key = 'recent_images';

  /// User-configurable cap (Settings > Output > Recent history), shared with
  /// the settings UI; [kRecentImagesCap] when unset. Read live on every
  /// load/add so a change applies without a relaunch.
  static const capKey = 'recent_images_cap';

  static Future<int> getCap(SettingsStore store) async {
    final v = await store.getInt(capKey);
    return (v == null || v < 1) ? kRecentImagesCap : v;
  }

  static Future<void> setCap(SettingsStore store, int cap) =>
      store.setInt(capKey, cap);

  Future<List<String>> load() async {
    final s = await store.getString(_key);
    if (s == null || s.isEmpty) return const [];
    try {
      final list = (jsonDecode(s) as List<dynamic>).cast<String>();
      // Apply the cap on read too, so REDUCING it takes effect immediately.
      final cap = await getCap(store);
      return list.length > cap ? list.sublist(0, cap) : list;
    } catch (_) {
      return const [];
    }
  }

  /// Record [path] as the most-recently-opened image (dedup + cap).
  Future<void> add(String path) async {
    final next = mergeRecent(await load(), path, cap: await getCap(store));
    await store.setString(_key, jsonEncode(next));
  }

  /// Drop [path] from the list (user removed it from the recent grid).
  Future<void> remove(String path) async {
    await store.setString(_key, jsonEncode(removeRecent(await load(), path)));
  }

  Future<void> clear() => store.remove(_key);
}
