/// Why a hotkey could not be registered. macOS never produces these this slice
/// (it cannot detect conflicts); reserved for Windows (Phase 6 = alreadyInUse)
/// and a future macOS system-shortcut check (systemReserved).
enum UnavailableReason { alreadyInUse, systemReserved, error }

/// Result of a registration attempt. macOS returns [ok] (or [error] on an
/// exception); the unavailable reasons are populated by other platforms.
sealed class RegisterResult {
  const RegisterResult();
  const factory RegisterResult.ok() = RegisterOk;
  const factory RegisterResult.unavailable(UnavailableReason reason) =
      RegisterUnavailable;
}

class RegisterOk extends RegisterResult {
  const RegisterOk();
}

class RegisterUnavailable extends RegisterResult {
  const RegisterUnavailable(this.reason);
  final UnavailableReason reason;
}
