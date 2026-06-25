import 'dart:io' show Platform;

import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_windows/shared_preferences_windows.dart';

/// Force the CURRENT engine's persisted-settings cache to re-read from disk.
///
/// WHY THIS EXISTS (Windows-only): the macOS settings backend (NSUserDefaults via
/// shared_preferences_foundation) is process-global and uncached, so EVERY engine
/// always observes the latest writes -- glimpr's whole multi-engine model relies
/// on that, and this function is a deliberate NO-OP on macOS.
///
/// The Windows backend (SharedPreferencesAsyncWindows) instead caches preferences
/// in memory PER ENGINE INSTANCE and only refreshes on an explicit reload. So one
/// engine never sees ANOTHER engine's later writes until it reloads. Two known
/// cross-engine cases: (1) the resident overlay engine reading settings the
/// control engine wrote (decoration, loupe size/zoom, ...); (2) the control
/// engine reading the `last_region` the overlay engine wrote after a crop. Call
/// this before such a cross-engine read. Best-effort: any failure leaves the
/// existing cached values (a stale read is acceptable; a crash is not).
Future<void> reloadSettingsCache() async {
  if (!Platform.isWindows) return;
  final platform = SharedPreferencesAsyncPlatform.instance;
  if (platform is SharedPreferencesAsyncWindows) {
    try {
      // reload() is the only API that drops the per-instance cache; it is
      // annotated @visibleForTesting upstream but is the sanctioned way to force
      // a fresh disk read for this cross-engine case.
      // ignore: invalid_use_of_visible_for_testing_member
      await platform.reload(const SharedPreferencesWindowsOptions());
    } catch (_) {
      // Keep the cached values.
    }
  }
}
