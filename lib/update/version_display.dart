/// The ONE user-facing version format: GitHub is the version source of truth
/// and names releases `vX.Y.Z`, so every surface the user can see (About
/// pane, tray menu, update rows, What's new, diagnostics) shows the same
/// leading `v`. Native tray code mirrors this rule (it cannot call Dart).
///
/// Accepts either form ("1.18.0 (31)", "v1.18.0", "V1.18.0") and returns
/// "v1.18.0 (31)" / "v1.18.0"; empty stays empty.
String displayVersion(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return s;
  if (s.startsWith('v')) return s;
  if (s.startsWith('V')) return 'v${s.substring(1)}';
  return 'v$s';
}

/// The numeric core of any version string the app sees: "1.20.0 (33)",
/// "v1.20.0" and "V1.20.0 (2)" all give "1.20.0". Release tags are compared
/// and resolved on this core (an rc suffix lives only in the tag).
String versionCore(String raw) {
  var s = raw.trim();
  final space = s.indexOf(' ');
  if (space != -1) s = s.substring(0, space);
  if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
  return s;
}
