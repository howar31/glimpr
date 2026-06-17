/// Geometry config for the pixel loupe, shared by the capture overlay and the
/// standalone Image Editor. [span] is how many native pixels the loupe shows per
/// axis; [zoom] is how many loupe px each native pixel is drawn at (the
/// magnification). The on-screen box is [box] = span * zoom — the window grows
/// with the size while the per-pixel magnification stays fixed.
const int kLoupeSpanMin = 5;
const int kLoupeSpanMax = 20;
const int kLoupeSpanDefault = 12;
const int kLoupeZoomMin = 4;
const int kLoupeZoomMax = 16;
const int kLoupeZoomDefault = 8;

/// What the loupe shows beneath the glass; cycled by `?` / `/` (a fixed, not
/// rebindable, shortcut): coordinates -> element level -> shortcuts -> hidden.
/// Persisted (see [LoupeConfig.infoMode]) so the choice survives relaunch.
enum LoupeInfoMode { coords, level, shortcuts, hidden }

class LoupeConfig {
  final int span; // native px shown per axis
  final int zoom; // loupe px per native px (magnification)

  /// What a tool shortcut does while the eyedropper is sampling: true (the
  /// default) cancels sampling and switches; false keeps sampling MODAL —
  /// tool switches are ignored, so a stray key cannot kick the user out of a
  /// carefully aimed sample.
  final bool toolKeysCancelSampling;

  /// The persisted loupe-info-display choice (`?`/`/` cycle). Seeds the
  /// process-global cycle on the first editor of a session so a relaunch
  /// restores the last choice; the live cycle then owns it and writes back via
  /// [Settings.setLoupeInfoMode] (see EditorCore's host persist callback).
  final LoupeInfoMode infoMode;

  const LoupeConfig({
    this.span = kLoupeSpanDefault,
    this.zoom = kLoupeZoomDefault,
    this.toolKeysCancelSampling = true,
    this.infoMode = LoupeInfoMode.coords,
  });

  /// Builds a config clamped to the valid ranges; null inputs fall back to the
  /// defaults. Use when reading from the store (a corrupt value stays safe).
  factory LoupeConfig.clamped({
    int? span,
    int? zoom,
    bool? toolKeysCancelSampling,
    LoupeInfoMode? infoMode,
  }) =>
      LoupeConfig(
        span: (span ?? kLoupeSpanDefault).clamp(kLoupeSpanMin, kLoupeSpanMax),
        zoom: (zoom ?? kLoupeZoomDefault).clamp(kLoupeZoomMin, kLoupeZoomMax),
        toolKeysCancelSampling: toolKeysCancelSampling ?? true,
        infoMode: infoMode ?? LoupeInfoMode.coords,
      );

  /// The loupe's on-screen box size (logical px), square.
  double get box => (span * zoom).toDouble();

  @override
  bool operator ==(Object other) =>
      other is LoupeConfig &&
      other.span == span &&
      other.zoom == zoom &&
      other.toolKeysCancelSampling == toolKeysCancelSampling &&
      other.infoMode == infoMode;

  @override
  int get hashCode =>
      Object.hash(span, zoom, toolKeysCancelSampling, infoMode);
}
