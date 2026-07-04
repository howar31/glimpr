/// Why a hotkey could not be registered. Both platforms currently report only
/// [error] (an unmappable key or a native registration failure); the enum stays
/// so a finer-grained reason can be added without reshaping RegisterResult.
enum UnavailableReason { error }

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
