import 'dart:convert';
import 'dart:ui' show Rect;
import '../settings/settings_store.dart';

/// The rect of the most recent capture, on a specific display (display-local
/// logical, top-left). Recorded by every capture so "Capture Last Region" can
/// repeat it. A snap is recorded as the resolved fixed rect, not a live window.
class LastRegion {
  const LastRegion({required this.displayId, required this.rect});
  final int displayId;
  final Rect rect;
}

/// Persists [LastRegion] as JSON in the shared settings store (NSUserDefaults),
/// so the overlay engine (writer) and the control engine (reader) share it and
/// it survives a restart.
class LastRegionStore {
  LastRegionStore(this.store);
  final SettingsStore store;
  static const _key = 'last_region';

  Future<void> save(LastRegion r) => store.setString(
        _key,
        jsonEncode({
          'displayId': r.displayId,
          'x': r.rect.left,
          'y': r.rect.top,
          'w': r.rect.width,
          'h': r.rect.height,
        }),
      );

  Future<LastRegion?> load() async {
    final s = await store.getString(_key);
    if (s == null || s.isEmpty) return null;
    try {
      final m = jsonDecode(s) as Map<String, dynamic>;
      return LastRegion(
        displayId: (m['displayId'] as num).toInt(),
        rect: Rect.fromLTWH((m['x'] as num).toDouble(), (m['y'] as num).toDouble(),
            (m['w'] as num).toDouble(), (m['h'] as num).toDouble()),
      );
    } catch (_) {
      return null;
    }
  }
}
