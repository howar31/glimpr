import 'dart:ui' show Rect;

/// A live Accessibility (AX) element snap candidate, resolved at the cursor
/// during a screenshot overlay session (Advanced "precise element snap"). [rect]
/// is display-local LOGICAL (top-left). [winBounds] is the owning window's
/// CURRENT bounds and [windowId] keys it back to the freeze-time [SnapWindow] —
/// together they drive the frozen-vs-live divergence metric (the geometry may
/// have moved since the freeze; this feature MEASURES that rather than guarding).
class ElementSnap {
  const ElementSnap({
    required this.rect,
    required this.role,
    required this.title,
    required this.app,
    required this.latencyUs,
    this.appliedWalk = 0,
    this.windowId,
    this.winBounds,
  });

  final Rect rect;
  final String role; // AX role, e.g. AXButton
  final String title; // AX title/description
  final String app; // owning app localized name
  final int latencyUs; // native AX query latency (microseconds)
  // The tree-walk depth ACTUALLY applied (native stops at the real root/leaf), so
  // the caller can clamp its counter and never overshoot the real tree depth.
  final int appliedWalk;
  final int? windowId; // owning window's CGWindowID, or null if unresolved
  final Rect? winBounds; // owning window CURRENT bounds (display-local logical)

  /// Best human label for the saved file: title, else app, else role.
  String get label => title.isNotEmpty ? title : (app.isNotEmpty ? app : role);

  static Rect _r(Map m, String x, String y, String w, String h) =>
      Rect.fromLTWH((m[x] as num).toDouble(), (m[y] as num).toDouble(),
          (m[w] as num).toDouble(), (m[h] as num).toDouble());

  factory ElementSnap.fromMap(Map<dynamic, dynamic> m) => ElementSnap(
        rect: _r(m, 'x', 'y', 'w', 'h'),
        role: (m['role'] as String?) ?? '',
        title: (m['title'] as String?) ?? '',
        app: (m['app'] as String?) ?? '',
        latencyUs: (m['latencyUs'] as num?)?.toInt() ?? 0,
        appliedWalk: (m['appliedWalk'] as num?)?.toInt() ?? 0,
        windowId: (m['windowId'] as num?)?.toInt(),
        winBounds:
            m['winW'] == null ? null : _r(m, 'winX', 'winY', 'winW', 'winH'),
      );

  /// Geometry divergence vs a freeze-time window rect (matched by windowId):
  /// (movedDx, movedDy, resized). Null when either bound is unknown.
  ({double dx, double dy, bool resized})? divergence(Rect? freezeRect) {
    final wb = winBounds;
    if (wb == null || freezeRect == null) return null;
    return (
      dx: wb.left - freezeRect.left,
      dy: wb.top - freezeRect.top,
      resized: (wb.width - freezeRect.width).abs() > 1 ||
          (wb.height - freezeRect.height).abs() > 1,
    );
  }
}
