/// Public CONTRACT + free-build STUB for Glimpr's Pro license gate.
///
/// This package ships in the open-source repo. It declares the interface the
/// core calls and a no-op stub that reports every Pro capability as `locked`,
/// so the OSS build compiles and runs as a genuine free tier. The REAL
/// implementation — offline license verification AND the Pro feature code —
/// lives in a SAME-NAMED private package, swapped in at build time via
/// `pubspec_overrides.yaml`. Editing this stub to report `unlocked` only lights
/// a dead affordance: the Pro feature code is not present in the OSS build.
library;

/// A gateable Pro capability. Placeholder until the first Pro feature is chosen;
/// the enum is part of the public contract so the core can reference a stable
/// feature id at its gate points.
enum Feature {
  placeholder,
}

/// Entitlement state for a Pro [Feature]. Platform-aware: a Pro feature with no
/// implementation on the current platform reports [unavailableOnPlatform]
/// rather than [locked], so the UI can say "not available here" instead of
/// "buy to unlock".
enum FeatureState {
  unlocked,
  locked,
  unavailableOnPlatform,
}

/// The gate the core queries. The real implementation performs offline license
/// verification; the stub below always reports `locked`.
abstract class ProGate {
  /// Loads any stored license and resolves entitlement. Must never throw and
  /// must never block boot — a missing/invalid/slow license resolves to "no
  /// entitlement" (everything locked).
  Future<void> init();

  /// The current entitlement state for [feature]. Synchronous: reads the state
  /// resolved by [init].
  FeatureState state(Feature feature);
}

class _StubGate implements ProGate {
  @override
  Future<void> init() async {}

  @override
  FeatureState state(Feature feature) => FeatureState.locked;
}

/// Boot entry point + global accessor for the Pro gate. The core calls
/// [install] once per engine at startup, then queries [gate] at each gate
/// point. In the OSS build this installs the stub (every feature locked).
class ProRuntime {
  ProRuntime._();

  static ProGate gate = _StubGate();

  static Future<void> install() async {
    await gate.init();
  }
}
