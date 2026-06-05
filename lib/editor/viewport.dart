import 'dart:ui';

/// Zoom/pan view transform for the editor canvas. Maps the logical canvas
/// (image space) to on-screen local coordinates: local = logical*scale + offset.
/// Identity = 1:1, no pan (the capture overlay always uses this).
class EditorViewport {
  final double scale;
  final Offset offset;
  const EditorViewport({required this.scale, required this.offset});
  static const identity = EditorViewport(scale: 1.0, offset: Offset.zero);

  Offset toLogical(Offset local) => (local - offset) / scale;
  Offset toLocal(Offset logical) => logical * scale + offset;

  /// Zoom to [newScale] while keeping the logical point under [localAnchor] fixed.
  EditorViewport zoomedAround(Offset localAnchor, double newScale) {
    final logicalAnchor = toLogical(localAnchor);
    final newOffset = localAnchor - logicalAnchor * newScale;
    return EditorViewport(scale: newScale, offset: newOffset);
  }

  EditorViewport pannedBy(Offset localDelta) =>
      EditorViewport(scale: scale, offset: offset + localDelta);

  /// Fit [logical] centred inside [box], never upscaling past [maxScale].
  static EditorViewport fit(Size logical, Size box, {double maxScale = 1.0}) {
    if (logical.width <= 0 || logical.height <= 0) return identity;
    final s = (box.width / logical.width)
        .clamp(0.0, box.height / logical.height)
        .clamp(0.0, maxScale);
    final scaled = Size(logical.width * s, logical.height * s);
    return EditorViewport(
      scale: s == 0 ? 1.0 : s,
      offset: Offset((box.width - scaled.width) / 2, (box.height - scaled.height) / 2),
    );
  }
}
