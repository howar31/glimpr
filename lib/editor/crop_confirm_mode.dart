/// When a crop / region-selection drag is confirmed. `release`: the moment the
/// mouse is let go (the overlay's original behaviour). `adjust`: the drag
/// leaves a pending, editable selection (handles / move / ✔✖ / Enter / Esc)
/// that a confirm commits (the Image Editor's original behaviour). Persisted
/// PER SURFACE (overlay incl. record-select, and the editor) as the enum name.
enum CropConfirmMode { release, adjust }

/// Parses a stored enum name; an unknown / missing name yields [fallback].
CropConfirmMode cropConfirmModeFrom(String? name, CropConfirmMode fallback) =>
    CropConfirmMode.values.where((m) => m.name == name).firstOrNull ??
    fallback;
