import '../overlay/selection_guides.dart';

/// User-tunable HUD options for the capture overlay + image editor, loaded from
/// settings by the host app and passed into [EditorCore] (like [LoupeConfig]) so
/// both surfaces behave identically.
class HudConfig {
  /// Show the full-screen precise-aim crosshair lines for the crosshair tools.
  /// The reticle stays regardless; this toggles only the screen-wide lines.
  /// Persistent default; the toolbar / hotkey override it per session.
  final bool crosshair;

  /// Show the pixel loupe (magnifier) for the loupe tools + eyedropper. The
  /// reticle stays regardless; this toggles only the magnifier. Persistent
  /// default; the toolbar / hotkey override it per session.
  final bool loupe;

  /// Animate the HUD dashes as marching ants. When false the dashes are static
  /// (still two-tone dashed, just not flowing) — cheaper, less motion.
  final bool marchingAnts;

  /// Composition guide lines inside the crop selection (grid / diagonals /
  /// none) and the independent center mark. Config, not session state: the
  /// host re-seeds them on every settings reload.
  final GuideLines guideLines;
  final bool guideCenter;

  /// Whether the guides start VISIBLE each session. Persistent default; the
  /// toolbar / G hotkey override it per session (like [crosshair]).
  final bool guideShown;

  const HudConfig({
    this.crosshair = true,
    this.loupe = true,
    this.marchingAnts = true,
    this.guideLines = GuideLines.none,
    this.guideCenter = false,
    this.guideShown = false,
  });
}
