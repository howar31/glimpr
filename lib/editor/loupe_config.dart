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

class LoupeConfig {
  final int span; // native px shown per axis
  final int zoom; // loupe px per native px (magnification)

  const LoupeConfig({
    this.span = kLoupeSpanDefault,
    this.zoom = kLoupeZoomDefault,
  });

  /// Builds a config clamped to the valid ranges; null inputs fall back to the
  /// defaults. Use when reading from the store (a corrupt value stays safe).
  factory LoupeConfig.clamped({int? span, int? zoom}) => LoupeConfig(
    span: (span ?? kLoupeSpanDefault).clamp(kLoupeSpanMin, kLoupeSpanMax),
    zoom: (zoom ?? kLoupeZoomDefault).clamp(kLoupeZoomMin, kLoupeZoomMax),
  );

  /// The loupe's on-screen box size (logical px), square.
  double get box => (span * zoom).toDouble();

  @override
  bool operator ==(Object other) =>
      other is LoupeConfig && other.span == span && other.zoom == zoom;

  @override
  int get hashCode => Object.hash(span, zoom);
}
