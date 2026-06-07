/// User-tunable HUD options for the capture overlay + image editor, loaded from
/// settings by the host app and passed into [EditorCore] (like [LoupeConfig]) so
/// both surfaces behave identically.
class HudConfig {
  /// Show the full-screen precise-aim crosshair lines (region tools: crop / blur
  /// / pixelate). The small centre reticle + loupe stay regardless; this toggles
  /// only the screen-wide lines.
  final bool crosshair;

  /// Animate the HUD dashes as marching ants. When false the dashes are static
  /// (still two-tone dashed, just not flowing) — cheaper, less motion.
  final bool marchingAnts;

  const HudConfig({this.crosshair = true, this.marchingAnts = true});
}
