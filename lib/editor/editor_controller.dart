import 'dart:ui' show Color, Image, Offset, Size;
import 'package:flutter/foundation.dart';
import 'curve.dart';
import 'draw_style.dart';
import 'drawable.dart';
import 'document.dart';
import 'spotlight.dart';

/// Fixed down-right offset applied to a duplicated annotation so the copy is
/// visibly distinct from and grabbable over its source.
const kDuplicateOffset = Offset(16, 16);

enum ToolKind {
  crop,
  rectangle,
  ellipse,
  arrow,
  line,
  pen,
  highlighter,
  text,
  step,
  blur,
  pixelate,
  paste,
  stamp,
  magnify,
  spotlight,
}

enum EditorPhase { annotate, crop }

/// Factory-default style for a tool. Tools share the uniform default except the
/// highlighter, which defaults to a translucent marker colour so it reads as a
/// highlighter out of the box — its painter honours the colour's alpha (no
/// forced opacity), so the default carries the translucency.
DrawStyle defaultStyleFor(ToolKind t) => t == ToolKind.highlighter
    ? const DrawStyle(color: kHighlighterDefaultColor)
    : const DrawStyle();

/// The drawing [ToolKind] a drawable corresponds to, for driving the option bar
/// off the SELECTED annotation (so the universal Select tool can edit any of
/// them). Blur/Pixelate map to their tools (they expose a strength control); only
/// a pasted image has no editable option-bar style.
ToolKind? toolKindForDrawable(Drawable d) => switch (d) {
      RectangleDrawable() => ToolKind.rectangle,
      EllipseDrawable() => ToolKind.ellipse,
      ArrowDrawable() => ToolKind.arrow,
      LineDrawable() => ToolKind.line,
      HighlighterDrawable() => ToolKind.highlighter,
      PenDrawable() => ToolKind.pen,
      TextDrawable() => ToolKind.text,
      StepDrawable() => ToolKind.step,
      BlurDrawable() => ToolKind.blur,
      PixelateDrawable() => ToolKind.pixelate,
      MagnifyDrawable() => ToolKind.magnify,
      SpotlightDrawable() => ToolKind.spotlight,
      ImageDrawable() => null,
    };

/// Mutable editor state exposed as ValueListenables so widgets rebuild narrowly.
/// Defaults to the Crop tool — most captures are a plain crop; annotation tools
/// are opt-in (Flow B: draw first if you want, then crop).
class EditorController {
  /// Last-used style per tool, remembered across tool switches (and, when the
  /// same map instance is reused, across captures). Owned externally so it
  /// survives the controller being recreated for a new capture.
  final Map<ToolKind, DrawStyle> toolStyles;

  final tool = ValueNotifier<ToolKind>(ToolKind.crop);
  final style = ValueNotifier<DrawStyle>(const DrawStyle());
  final document = ValueNotifier<EditorDocument>(const EditorDocument());
  final selectedIndex = ValueNotifier<int?>(null);
  final phase = ValueNotifier<EditorPhase>(EditorPhase.crop);

  /// Eyedropper (colour sampler) mode: set by the colour picker's eyedropper
  /// button, consumed by EditorCore (which samples the base image on the next
  /// click, sets the colour, and clears this). A shared notifier is the channel
  /// between the popover and the canvas.
  final eyedropperActive = ValueNotifier<bool>(false);
  void startEyedropper() => eyedropperActive.value = true;
  void stopEyedropper() => eyedropperActive.value = false;

  /// Whether the captured mouse-pointer layer (overlay only) is shown. Initialised
  /// per capture from the "capture mouse pointer" setting; flipped by the toolbar
  /// cursor button; read by EditorCore (render) + the export.
  final showCursor = ValueNotifier<bool>(false);

  /// The current "stamp" image (file-loaded) the stamp tool places, or null
  /// until one is chosen. Session-scoped; not persisted across captures.
  final stampImage = ValueNotifier<Image?>(null);
  void setStampImage(Image? img) => stampImage.value = img;

  /// The encoded bytes of [stampImage], kept so the overlay can BROADCAST the
  /// stamp to the other displays (each decodes its own ui.Image — images cannot
  /// cross Flutter engines). Null until a stamp is chosen.
  Uint8List? stampBytes;

  /// Set the stamp image and its source bytes together (bytes first so a
  /// stampImage listener that broadcasts sees a consistent pair).
  void setStamp(Image img, Uint8List bytes) {
    stampBytes = bytes;
    stampImage.value = img;
  }

  /// Pick-request channel for the stamp tool (mirrors [eyedropperActive]): the
  /// option-bar button and selecting the empty stamp tool bump this; EditorCore
  /// listens and opens the file picker.
  final stampPick = ValueNotifier<int>(0);
  void requestStampPick() => stampPick.value++;

  /// Bumped to ask the live editor to RE-ACQUIRE keyboard focus — after a modal
  /// dialog closes (overlay discard prompt) or the window regains key (Cmd-Tab
  /// back to the image editor). Tool shortcuts run through the editor's FocusNode,
  /// which a popped route / window-key change doesn't reliably restore; EditorCore
  /// listens here and re-requests focus so shortcuts work without a manual click.
  final refocus = ValueNotifier<int>(0);
  void requestFocus() => refocus.value++;

  EditorController({Map<ToolKind, DrawStyle>? toolStyles})
    : toolStyles = toolStyles ?? {} {
    // Seed the active style from any remembered tool so a fresh capture keeps
    // the user's last look instead of resetting to defaults.
    final seed =
        this.toolStyles[ToolKind.rectangle] ??
        this.toolStyles[ToolKind.arrow] ??
        this.toolStyles[ToolKind.text];
    if (seed != null) style.value = seed;
    // The option bar reflects the SELECTED annotation's style (and reverts to the
    // tool's remembered style on deselect), so editing/Reset clearly act on it.
    selectedIndex.addListener(_syncStyleToSelection);
  }

  /// Load the selected drawable's style into the option bar; on deselect, restore
  /// the active tool's remembered style so the brush isn't left stuck on it.
  void _syncStyleToSelection() {
    final i = selectedIndex.value;
    if (i == null || i >= document.value.drawables.length) {
      if (tool.value != ToolKind.crop) {
        style.value = toolStyles[tool.value] ?? defaultStyleFor(tool.value);
      }
      return;
    }
    final d = document.value.drawables[i];
    // Pasted images have no editable option-bar style. Blur/Pixelate DO sync now
    // (they expose a per-region strength), so the option bar reflects the region.
    if (d is ImageDrawable) return;
    style.value = d.style;
  }

  void selectTool(ToolKind t) {
    tool.value = t;
    phase.value = t == ToolKind.crop ? EditorPhase.crop : EditorPhase.annotate;
    selectedIndex.value = null; // switching tools drops the per-type selection
    if (t != ToolKind.crop) {
      final saved = toolStyles[t];
      if (saved != null) {
        style.value = saved; // restore this tool's last style
      } else if (t == ToolKind.highlighter) {
        // The highlighter needs its translucent default, not the carried-over
        // (often opaque) style of the previously-used tool.
        style.value = defaultStyleFor(t);
      }
    }
  }

  void setColor(Color c) => _updateStyle(style.value.copyWith(color: c));
  void setStrokeWidth(double w) =>
      _updateStyle(style.value.copyWith(strokeWidth: w));
  void setFontSize(double s) => _updateStyle(style.value.copyWith(fontSize: s));
  void setHighlighterTexture(HighlighterTexture t) =>
      _updateStyle(style.value.copyWith(texture: t));
  void setFontFamily(String? f) =>
      _updateStyle(style.value.copyWith(fontFamily: f));
  void setShadow(bool s) => _updateStyle(style.value.copyWith(shadow: s));
  void setLineStyle(LineStyle s) =>
      _updateStyle(style.value.copyWith(lineStyle: s));
  void setArrowHeads(ArrowHeads h) =>
      _updateStyle(style.value.copyWith(arrowHeads: h));
  void setArrowHeadScale(double s) => _updateStyle(style.value.copyWith(
      arrowHeadScale: s.clamp(kArrowHeadScaleMin, kArrowHeadScaleMax)));
  void setStepStart(int n) => _updateStyle(
      style.value.copyWith(stepStart: n.clamp(kStepStartMin, kStepStartMax)));
  void setStepShape(StepShape s) =>
      _updateStyle(style.value.copyWith(stepShape: s));
  void setMagnifyFactor(double f) => _updateStyle(style.value.copyWith(
      magnifyFactor: f.clamp(kMagnifyFactorMin, kMagnifyFactorMax)));
  void setMagnifyConnector(bool on) =>
      _updateStyle(style.value.copyWith(magnifyConnector: on));
  void setSpotlightDim(int v) => _updateStyle(style.value
      .copyWith(spotlightDim: v.clamp(kSpotlightDimMin, kSpotlightDimMax)));
  void setSpotlightEffect(SpotlightEffect e) =>
      _updateStyle(style.value.copyWith(spotlightEffect: e));
  void setSpotlightFeather(double f) => _updateStyle(style.value.copyWith(
      spotlightFeather: f.clamp(kSpotlightFeatherMin, kSpotlightFeatherMax)));
  void setCurvePoints(int n) => _updateStyle(style.value
      .copyWith(curvePoints: n.clamp(kCurvePointsMin, kCurvePointsMax)));
  void setStrength(double s) => _updateStyle(style.value
      .copyWith(strength: s.clamp(kRasterStrengthMin, kRasterStrengthMax)));
  // Rect/ellipse fill. Canonicalize a fully transparent pick to the exact "no
  // fill" default so equality (reset-button enablement) and JSON omission agree.
  void setFillColor(Color c) => _updateStyle(style.value
      .copyWith(fillColor: c.a == 0 ? const Color(0x00000000) : c));
  // Text glyph outline. Canonicalize a fully transparent pick to the exact "no
  // outline" default (same rationale as setFillColor).
  void setOutlineColor(Color c) => _updateStyle(style.value
      .copyWith(outlineColor: c.a == 0 ? const Color(0x00000000) : c));
  void setCornerRadius(double r) => _updateStyle(
      style.value.copyWith(cornerRadius: r.clamp(0.0, kCornerRadiusMax)));
  // Revert ONLY the corner radius to the legacy auto value (bypasses the
  // setCornerRadius clamp, which would pin the sentinel to 0). Lets the option bar
  // offer a per-field "Auto" without the all-options reset button.
  void setCornerRadiusAuto() =>
      _updateStyle(style.value.copyWith(cornerRadius: kCornerRadiusAuto));

  // copyWith cannot clear fontFamily back to null (null means "keep existing"),
  // so we rebuild the style explicitly without a fontFamily. The other fields
  // (incl. shadow + texture) carry over so clearing the font doesn't reset them.
  void resetFontFamily() => _updateStyle(
    DrawStyle(
      color: style.value.color,
      strokeWidth: style.value.strokeWidth,
      fontSize: style.value.fontSize,
      texture: style.value.texture,
      shadow: style.value.shadow,
    ),
  );

  /// Restore [t] to the factory default style and make it active if it is the
  /// current tool. Clears the per-tool memory entry.
  void resetTool(ToolKind t) {
    final def = defaultStyleFor(t);
    toolStyles[t] = def;
    if (tool.value == t) {
      style.value = def;
      _restyleSelected();
    }
  }

  /// Reset the option bar's CURRENT subject to its factory default. [effective] is
  /// the type the option bar is showing — the selected annotation's type when one
  /// is selected (so the universal Select tool resets it to ITS type's default
  /// without touching the active tool), else the active tool. Resets the active
  /// tool's remembered style only when nothing is selected and it IS that type;
  /// with a selection this resets ONLY that drawable, leaving the tool default
  /// intact (uniform with the Select tool).
  void resetActiveStyle(ToolKind effective) {
    final def = defaultStyleFor(effective);
    if (!_hasSelection && tool.value == effective) toolStyles[effective] = def;
    style.value = def;
    _restyleSelected();
  }

  /// True when a drawable is currently selected, so an option-bar change is an
  /// EDIT of that drawable rather than setting the active tool's default.
  bool get _hasSelection {
    final i = selectedIndex.value;
    return i != null && i < document.value.drawables.length;
  }

  void _updateStyle(DrawStyle s) {
    style.value = s;
    // No selection -> set the active tool's default for future shapes (remembered
    // per tool). A selection -> this is an EDIT of that drawable only; leave the
    // tool's default untouched so deselecting restores it. This makes every tool
    // behave like the universal Select tool, whose edits would otherwise land on
    // the never-read paste slot rather than the drawn type's default.
    if (!_hasSelection && tool.value != ToolKind.crop) {
      toolStyles[tool.value] = s;
    }
    final i = selectedIndex.value;
    final sel = (i != null && i < document.value.drawables.length)
        ? document.value.drawables[i]
        : null;
    if (sel is SpotlightDrawable) {
      // The selected hole takes the FULL style (incl. per-hole cornerRadius);
      // the other holes take the layer-wide fields — one commit, one undo step.
      _restyleSpotlights(i!);
    } else {
      _restyleSelected();
      _syncSpotlightLayer(); // no-op unless the spotlight TOOL is active
    }
  }

  /// Spotlight restyle: the selected hole takes the full bar style (incl.
  /// per-hole cornerRadius); every other hole takes only the layer-wide fields.
  /// ONE withDrawables commit = one undo step.
  void _restyleSpotlights(int selected) {
    final src = style.value;
    final drawables = document.value.drawables;
    var changed = false;
    final next = <Drawable>[];
    for (var k = 0; k < drawables.length; k++) {
      final d = drawables[k];
      if (d is! SpotlightDrawable) {
        next.add(d);
        continue;
      }
      final want = k == selected ? src : mergeSpotlightLayerFields(d.style, src);
      if (want != d.style) changed = true;
      next.add(d.withStyle(want));
    }
    if (changed) document.value = document.value.withDrawables(next);
  }

  /// ONE background per image: with the spotlight TOOL active and nothing
  /// selected, a bar change still updates the layer — copy the layer-wide fields
  /// (dim/effect/strength/feather) onto EVERY spotlight drawable. Per-hole
  /// fields stay untouched. No-op when nothing changes (no undo-stack spam).
  void _syncSpotlightLayer() {
    if (_hasSelection || tool.value != ToolKind.spotlight) return;
    final src = style.value;
    var changed = false;
    final next = <Drawable>[];
    for (final d in document.value.drawables) {
      if (d is SpotlightDrawable) {
        final merged = mergeSpotlightLayerFields(d.style, src);
        if (merged != d.style) {
          changed = true;
          next.add(d.withStyle(merged));
          continue;
        }
      }
      next.add(d);
    }
    if (changed) document.value = document.value.withDrawables(next);
  }

  /// Commit a new spotlight hole: append it AND equalise the layer-wide fields
  /// of every existing hole to the new one's, in ONE undoable commit.
  void commitSpotlight(SpotlightDrawable d) {
    final next = <Drawable>[
      for (final e in document.value.drawables)
        e is SpotlightDrawable
            ? e.withStyle(mergeSpotlightLayerFields(e.style, d.style))
            : e,
      d,
    ];
    document.value = document.value.withDrawables(next);
  }

  /// "Edit": when a drawable is selected (hovered/clicked), a style change also
  /// updates that drawable, not just the style for future ones.
  void _restyleSelected() {
    final i = selectedIndex.value;
    if (i == null || i >= document.value.drawables.length) return;
    final d = document.value.drawables[i];
    final Drawable restyled = switch (d) {
      RectangleDrawable() => d.withStyle(style.value),
      EllipseDrawable() => d.withStyle(style.value),
      ArrowDrawable() => d.withStyle(style.value),
      LineDrawable() => d.withStyle(style.value),
      HighlighterDrawable() => d.withStyle(style.value),
      PenDrawable() => d.withStyle(style.value),
      TextDrawable() => d.withStyle(style.value),
      StepDrawable() => d.withStyle(style.value),
      // Raster regions carry an editable strength (blur radius / block size).
      BlurDrawable() => d.withStyle(style.value),
      PixelateDrawable() => d.withStyle(style.value),
      MagnifyDrawable() => d.withStyle(style.value),
      SpotlightDrawable() => d.withStyle(style.value),
      // Pasted images carry no editable style.
      ImageDrawable() => d,
    };
    // For the line tools, a changed curve-points count re-seeds the interior
    // control points evenly along the current spline (shape preserved).
    var result = restyled;
    if (result is Segmented) {
      final want =
          style.value.curvePoints.clamp(kCurvePointsMin, kCurvePointsMax);
      final seg = result as Segmented;
      if (seg.points.length - 2 != want) {
        result = seg.withPoints(resampleInterior(seg.points, want));
      }
    }
    document.value = document.value.replaceAt(i, result);
  }

  void commitDrawable(Drawable d) => document.value = document.value.add(d);

  /// Destructive crop-trim (image editor): push an undo snapshot with the new
  /// (already-shifted) drawables AND the cropped canvas [image] + [size].
  void commitTrim(List<Drawable> shifted, Image image, Size size) =>
      document.value = document.value.trimmed(shifted, image, size);

  void replaceSelected(Drawable d) {
    final i = selectedIndex.value;
    if (i != null) document.value = document.value.replaceAt(i, d);
  }

  void deleteSelected() {
    final i = selectedIndex.value;
    if (i != null) {
      document.value = document.value.removeAt(i);
      selectedIndex.value = null;
    }
  }

  /// Duplicate the selected drawable: insert an offset copy directly above it
  /// (index+1) and select the copy.
  void duplicateSelected() {
    final i = selectedIndex.value;
    if (i == null || i >= document.value.drawables.length) return;
    final copy = document.value.drawables[i].moved(kDuplicateOffset);
    document.value = document.value.insertAt(i + 1, copy);
    selectedIndex.value = i + 1;
  }

  /// Move the selected drawable to the top of the stack; keep it selected.
  void bringSelectedToFront() {
    final i = selectedIndex.value;
    if (i == null || i >= document.value.drawables.length) return;
    final last = document.value.drawables.length - 1;
    if (i == last) return;
    document.value = document.value.moveToFront(i);
    selectedIndex.value = last;
  }

  /// Move the selected drawable to the bottom of the stack; keep it selected.
  void sendSelectedToBack() {
    final i = selectedIndex.value;
    if (i == null || i <= 0 || i >= document.value.drawables.length) return;
    document.value = document.value.moveToBack(i);
    selectedIndex.value = 0;
  }

  void undo() => document.value = document.value.undo();
  void redo() => document.value = document.value.redo();

  void dispose() {
    tool.dispose();
    style.dispose();
    document.dispose();
    selectedIndex.dispose();
    phase.dispose();
    eyedropperActive.dispose();
    refocus.dispose();
    stampImage.dispose();
    stampPick.dispose();
  }
}
