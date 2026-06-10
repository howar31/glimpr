import 'dart:convert';
import '../settings/settings_store.dart';

/// Default cap on the recent-images list. The landing gallery scrolls, so the
/// cap is about history depth (and prune cost), not about what fits on screen.
const int kRecentImagesCap = 30;

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

  Future<List<String>> load() async {
    final s = await store.getString(_key);
    if (s == null || s.isEmpty) return const [];
    try {
      final list = jsonDecode(s) as List<dynamic>;
      return list.cast<String>();
    } catch (_) {
      return const [];
    }
  }

  /// Record [path] as the most-recently-opened image (dedup + cap).
  Future<void> add(String path) async {
    final next = mergeRecent(await load(), path);
    await store.setString(_key, jsonEncode(next));
  }

  /// Drop [path] from the list (user removed it from the recent grid).
  Future<void> remove(String path) async {
    await store.setString(_key, jsonEncode(removeRecent(await load(), path)));
  }

  Future<void> clear() => store.remove(_key);
}
