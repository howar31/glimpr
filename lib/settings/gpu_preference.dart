/// Which GPU the Flutter engines render on (Windows only; read NATIVELY at
/// process start by windows/runner/prefs_probe.h and applied through
/// DartProject::set_gpu_preference, so it is NOT part of the hot-reloading
/// AppConfig). Stored under `gpu_preference` as the wire name below; the native
/// probe compares the same strings, so NEVER rename a wire value.
///
/// `system` = no preference (Windows picks, normally the GPU the display is
/// wired to); `lowPower` = the integrated GPU when there is one, else the only
/// GPU; `highPerformance` = the discrete GPU when there is one. Restart-
/// effective for the main process; the overlay host is a fresh child per
/// screenshot session, so it follows the next session.
enum GpuPreference {
  system('system'),
  lowPower('low_power'),
  highPerformance('high_performance');

  const GpuPreference(this.wire);

  /// The persisted / native-shared identifier.
  final String wire;

  /// Unknown or missing values fall back to [system]; the native probe does
  /// the same, so both sides agree on the default.
  static GpuPreference fromWire(String? s) =>
      values.where((g) => g.wire == s).firstOrNull ?? GpuPreference.system;
}
