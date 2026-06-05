import 'dart:convert';
import '../settings/settings_store.dart';

/// Default cap on the recent-images list.
const int kRecentImagesCap = 10;

/// Move-to-front dedup: [added] becomes the head, any prior occurrence removed,
/// then the list is capped to [cap] (oldest dropped). Pure so it is unit-tested
/// without a store.
List<String> mergeRecent(List<String> existing, String added,
    {int cap = kRecentImagesCap}) {
  final out = <String>[added, ...existing.where((p) => p != added)];
  return out.length > cap ? out.sublist(0, cap) : out;
}

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

  Future<void> clear() => store.remove(_key);
}
