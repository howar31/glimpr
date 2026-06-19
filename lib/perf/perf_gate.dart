import 'package:shared_preferences/shared_preferences.dart';

/// Whether perf instrumentation (the per-frame [FrameStatsReporter] callback +
/// the perf marks) should run. Measurement tooling is fully inert in normal use
/// and only wakes when `defaults write com.howar31.glimpr debugHooks -bool YES`.
///
/// Mirrors the native `PerfLog.enabled` gate. The native side already drops
/// every emitted mark when this is off (race-free, read at launch); this Dart
/// gate additionally keeps the per-frame frame-stat callback from registering,
/// so no measurement work runs on the Dart side either. Read once per engine;
/// toggling `debugHooks` needs a relaunch. `SharedPreferencesAsync` uses raw
/// keys (no `flutter.` prefix), so it reads the `defaults`-written value.
Future<bool> perfGateEnabled() async {
  try {
    return (await SharedPreferencesAsync().getBool('debugHooks')) ?? false;
  } catch (_) {
    // No prefs backend (e.g. widget tests) -> measurement stays off (fail-safe).
    return false;
  }
}
