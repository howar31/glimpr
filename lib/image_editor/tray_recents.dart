import 'dart:io';
import 'package:flutter/services.dart';
import '../channels.dart';
import '../settings/prefs_cache.dart';
import '../settings/settings_store.dart';
import 'recent_images.dart';

/// Windows only: the control engine (always resident) feeds the tray
/// "Open Recent" submenu. The editor engine used to do it from its warm boot,
/// but on Windows that engine now lives in a child process that exists only
/// while the editor window is open, so the list would be empty until the
/// first open. macOS keeps the editor-fed path.
class TrayRecents {
  TrayRecents({
    required SettingsStore store,
    this.channel = kRoleChannel,
    bool Function(String path)? exists,
    Future<void> Function()? reload,
  })  : _store = RecentImagesStore(store),
        _exists = exists ?? _fileExists,
        _reload = reload ?? reloadSettingsCache;

  final RecentImagesStore _store;
  final MethodChannel channel;
  final bool Function(String path) _exists;
  final Future<void> Function() _reload;

  static bool _fileExists(String p) => File(p).existsSync();

  /// Reload the shared store (another engine may have written it), drop
  /// entries whose file is gone, and push the list to the tray. Never throws:
  /// a broken store yields an empty list.
  Future<List<String>> refresh() async {
    List<String> list;
    try {
      await _reload();
      list = pruneMissing(await _store.load(), _exists);
    } catch (_) {
      list = const [];
    }
    await _push(list);
    return list;
  }

  /// Tray "Clear Recent": empty the store and the submenu.
  Future<void> clear() async {
    try {
      await _store.clear();
    } catch (_) {}
    await _push(const []);
  }

  Future<void> _push(List<String> list) async {
    try {
      await channel.invokeMethod('setRecentImages', list);
    } catch (_) {
      // Channel unavailable (tests, macOS): the store is still the truth.
    }
  }
}
