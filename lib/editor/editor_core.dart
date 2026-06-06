import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import '../capture/captured_display.dart';
import '../shortcuts/hotkey_binding.dart';
import '../shortcuts/shortcut_actions.dart';
import '../overlay/crop_hud.dart';
import '../overlay/selection_controller.dart';
import '../overlay/selection_label.dart';
import '../overlay/selection_scrim.dart';
import '../overlay/toolbar.dart';
import '../overlay/window_snap.dart';
import 'drawable.dart';
import 'drawable_painter.dart';
import 'editor_controller.dart';
import 'editor_host.dart';
import 'hit_test.dart';
import 'raster.dart';
import 'text_metrics.dart';
import 'viewport.dart';

/// Shift-constrain a box drag to a SQUARE from anchor [a] toward [p]: side =
/// the larger of the two deltas, keeping the drag's quadrant. (Square bounding
/// box => a circle for the ellipse tool.)
Offset _squareCorner(Offset a, Offset p) {
  final dx = p.dx - a.dx;
  final dy = p.dy - a.dy;
  final s = math.max(dx.abs(), dy.abs());
  return Offset(a.dx + (dx < 0 ? -s : s), a.dy + (dy < 0 ? -s : s));
}

/// Like [_squareCorner] but capped so the corner stays inside [bounds] — used
/// for the crop selection, which (unlike annotations) must not leave the canvas.
Offset _squareCornerIn(Offset a, Offset p, Size bounds) {
  final dx = p.dx - a.dx;
  final dy = p.dy - a.dy;
  final availX = dx < 0 ? a.dx : bounds.width - a.dx;
  final availY = dy < 0 ? a.dy : bounds.height - a.dy;
  final s = math.min(math.min(dx.abs(), dy.abs()), math.min(availX, availY));
  return Offset(a.dx + (dx < 0 ? -s : s), a.dy + (dy < 0 ? -s : s));
}

/// Shift-constrain a segment drag to the nearest of 8 directions (multiples of
/// 45°) from anchor [a]: the moving point is projected onto that ray, so the tip
/// tracks the cursor along an axis/diagonal.
Offset _snap8(Offset a, Offset p) {
  final v = p - a;
  if (v.distance == 0) return p;
  const step = math.pi / 4; // 45°
  final snapped = (math.atan2(v.dy, v.dx) / step).round() * step;
  final dir = Offset(math.cos(snapped), math.sin(snapped));
  final proj = v.dx * dir.dx + v.dy * dir.dy; // |v| component along the ray
  return a + dir * proj;
}

/// In-overlay annotation editor for ONE display. Default tool is Crop; each
/// annotation tool manages only its OWN drawable type (hover highlights, drag
/// moves, tap edits, right-click deletes; right-click also cancels an in-progress
/// draw/crop). Crop dims only once a drag exists and shows a full-screen
/// crosshair + pixel loupe. Local gesture coords == display-local logical coords.
class EditorCore extends StatefulWidget {
  final EditorController controller;
  final Map<String, HotkeyBinding?> editorBindings;
  final EditorHost host;
  // Optional handle so a docked host toolbar (image editor) can drive the
  // viewport's Fit / 100% from outside; null for the overlay.
  final EditorViewportController? viewportController;
  const EditorCore({
    super.key,
    required this.controller,
    required this.editorBindings,
    required this.host,
    this.viewportController,
  });

  @override
  State<EditorCore> createState() => _EditorCoreState();
}

class _EditorCoreState extends State<EditorCore> {
  final _focus = FocusNode();
  final _crop = SelectionController();

  late Offset _cursor; // logical cursor (crosshair/loupe/nudge + hover)
  late Offset
  _toolbarPos; // bottom-left anchor (tool row's bottom) of the toolbar
  // The cursor is over THIS display -> show the interactive HUD/toolbar here.
  // Follows the mouse across displays; the launch (cursor) display starts active.
  late bool _active;
  // The pointer is over the CANVAS (not the toolbar) -> draw our reticle there
  // and hide the system cursor; over the toolbar we let the normal click cursor
  // show. Driven by the canvas MouseRegion's enter/exit.
  bool _overCanvas = false;
  bool _lastHide = false; // last system-cursor-hidden value pushed to native

  // ---- viewport (image editor only; identity for the overlay) ------------
  // The display transform mapping the logical canvas (image space) to on-screen
  // local coords. ONLY mutated inside `if (_interactive)` paths, so the overlay
  // (viewportInteractive == false) always renders at identity 1:1.
  EditorViewport _viewport = EditorViewport.identity;
  Size _lastBoxSize = Size.zero; // last LayoutBuilder constraints.biggest
  bool _didInitialFit = false; // fit-to-window done once per loaded image

  // New-shape preview (drag on empty).
  Drawable? _preview;
  Offset? _dragStart;
  List<Offset>?
  _strokePoints; // accumulated freehand points (pen + highlighter)
  // Whole frame pre-blurred / pre-pixelated once when the tool is selected; the
  // blur/pixelate regions just mask these (no per-frame recompute -> no lag).
  ui.Image? _blurredFull;
  ui.Image? _pixelatedFull;

  // Move/resize an existing drawable.
  int? _editIndex;
  Drawable? _editOriginal;
  Drawable? _editPreview;
  Offset? _moveStart;
  int? _resizeCorner; // 0=TL 1=TR 2=BR 3=BL on a RectangleDrawable
  int? _endpoint; // 0=start 1=end on a Segmented shape (line/arrow/highlighter)
  Offset? _dragPos; // last drag position, to re-apply a mid-drag Shift toggle

  bool _cropping = false;
  // Editor crop-trim: adjusting a PENDING (drag-released) selection before
  // confirm — resize from a corner or move the whole rect.
  int? _cropCorner; // 0=TL 1=TR 2=BR 3=BL during a corner-resize drag
  Offset? _cropMoveStart; // logical press point when moving the whole selection
  Rect? _cropMoveOrigin; // the pending rect at move-start
  bool get _cropAdjusting => _cropCorner != null || _cropMoveStart != null;

  // Snappable windows for THIS display (capture-time snapshot) + the one the
  // cursor is currently over (crop tool, not mid-drag) — highlighted + snapped.
  List<SnapWindow> _windows = const [];
  Rect? _hoverWindow;
  bool _cancelGesture = false; // right-click cancelled the active drag

  // Inline text editing — one uniform style per text box.
  final _textFocus = FocusNode();
  TextEditingController? _textCtl;
  Offset? _textPos;
  int? _editTextIndex; // re-editing an existing text drawable
  bool _editingText = false;

  EditorController get c => widget.controller;
  bool get _inCrop => c.phase.value == EditorPhase.crop;

  /// Whether this host drives a zoom/pan viewport (image editor) vs. identity
  /// 1:1 (capture overlay). When false EVERY viewport seam degenerates to the
  /// original behaviour: no Transform, `_toLogical` is identity.
  bool get _interactive => widget.host.viewportInteractive;

  /// The logical canvas size. For the editor it follows the document's mutable
  /// canvas size after a crop-trim (null = the host's untrimmed size); the
  /// overlay always uses the host size (it never trims).
  Size get _canvasSize => _interactive
      ? (c.document.value.canvasSize ?? widget.host.size)
      : widget.host.size;

  /// The current canvas image (loupe + raster + base layer). After a crop-trim
  /// it is the smaller document image; otherwise the host base image. The overlay
  /// never trims, so it is always the host base image.
  ui.Image get _canvasImage => _interactive
      ? (c.document.value.canvasImage ?? widget.host.baseImage)
      : widget.host.baseImage;

  /// Map a gesture-layer local position to logical canvas coords. The editor's
  /// gesture layer is positioned EXACTLY over the on-screen image rect (offset +
  /// scaled size), so its local coords are already image-relative — divide by the
  /// viewport scale for logical. The overlay's gesture layer is full-screen 1:1.
  Offset _toLogical(Offset local) =>
      _interactive ? local / _viewport.scale : local;

  static const _kDrawDevices = <PointerDeviceKind>{
    PointerDeviceKind.mouse,
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.unknown,
  };

  /// Fit the logical canvas centred inside [box] with a margin so the image is
  /// never edge-to-edge.
  EditorViewport _fittedViewport(Size box) {
    const margin = 48.0;
    final inner = Size(
      (box.width - margin * 2).clamp(1.0, box.width),
      (box.height - margin * 2).clamp(1.0, box.height),
    );
    final f = EditorViewport.fit(_canvasSize, inner);
    return EditorViewport(
      scale: f.scale,
      offset: f.offset + const Offset(margin, margin),
    );
  }

  /// Re-fit the canvas to the last laid-out box (⌘1). No-op when non-interactive.
  void _refitViewport() {
    if (!_interactive) return;
    setState(() => _viewport = _fittedViewport(_lastBoxSize));
  }

  /// Zoom to 100% (1:1) anchored on the box centre (⌘2). No-op for the overlay.
  void _zoomActualSize() {
    if (!_interactive) return;
    setState(
      () => _viewport = _viewport.zoomedAround(
        Offset(_lastBoxSize.width / 2, _lastBoxSize.height / 2),
        1.0,
      ),
    );
  }

  /// Confirm a pending crop selection (image editor): destructively trim the
  /// canvas to the rect — crop the current image to a new smaller [ui.Image],
  /// shift every drawable by -rect.topLeft, push an undo step, then drop the
  /// stale blur/pixelate pre-rasters and refit the viewport. Undo restores the
  /// pre-crop image + size + drawables.
  Future<void> _confirmTrim() async {
    final r = _crop.rect.value;
    if (r == null) return;
    // A drag can run past the image edges — clamp to the canvas.
    final rect = r.intersect(Offset.zero & _canvasSize);
    if (rect.width < 1 || rect.height < 1) {
      setState(() => _crop.clear());
      return;
    }
    final cropped = await _cropImage(_canvasImage, rect);
    if (!mounted) {
      cropped.dispose();
      return;
    }
    final shifted = [
      for (final d in c.document.value.drawables) d.moved(-rect.topLeft),
    ];
    c.commitTrim(shifted, cropped, rect.size);
    c.selectedIndex.value = null;
    // Stale pre-rasters (old size) -> drop + recompute from the trimmed image.
    _blurredFull?.dispose();
    _pixelatedFull?.dispose();
    _blurredFull = null;
    _pixelatedFull = null;
    setState(() {
      _crop.clear();
      _cropping = false;
    });
    _ensureRasterFor(c.tool.value);
    _refitViewport();
  }

  /// Crop [src] to [rect] (logical == pixels for the editor, pixelScale 1.0) into
  /// a new image. Base pixels only; annotations are not rasterized.
  Future<ui.Image> _cropImage(ui.Image src, Rect rect) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImageRect(src, rect, Offset.zero & rect.size, ui.Paint());
    final picture = recorder.endRecording();
    final img = await picture.toImage(rect.width.round(), rect.height.round());
    picture.dispose();
    return img;
  }

  static const double _kMinScale = 0.1;
  static const double _kMaxScale = 16.0;
  double _panZoomBaseScale = 1.0;
  bool _middlePanning = false; // middle mouse button (wheel press) viewport pan

  /// Mouse-wheel / two-finger scroll: Cmd+scroll = cursor-anchored zoom;
  /// Shift+scroll = horizontal pan (common convention); else pan.
  void _onPointerSignal(PointerSignalEvent e) {
    if (!_interactive || e is! PointerScrollEvent) return;
    if (HardwareKeyboard.instance.isMetaPressed) {
      final ns = (_viewport.scale * (1 - e.scrollDelta.dy * 0.0015))
          .clamp(_kMinScale, _kMaxScale);
      setState(() => _viewport = _viewport.zoomedAround(e.localPosition, ns));
    } else {
      var delta = e.scrollDelta;
      if (HardwareKeyboard.instance.isShiftPressed) {
        // Map the wheel's dominant axis to horizontal (most mice report the
        // vertical wheel; some setups pre-swap to horizontal under Shift).
        final mag = delta.dy.abs() >= delta.dx.abs() ? delta.dy : delta.dx;
        delta = Offset(mag, 0);
      }
      setState(() => _viewport = _viewport.pannedBy(-delta));
    }
  }

  void _onPanZoomStart(PointerPanZoomStartEvent e) {
    _panZoomBaseScale = _viewport.scale;
  }

  /// Trackpad pinch = cursor-anchored zoom; two-finger drag during pinch = pan.
  void _onPanZoomUpdate(PointerPanZoomUpdateEvent e) {
    if (!_interactive) return;
    final ns = (_panZoomBaseScale * e.scale).clamp(_kMinScale, _kMaxScale);
    setState(
      () => _viewport =
          _viewport.zoomedAround(e.localPosition, ns).pannedBy(e.panDelta),
    );
  }

  // Middle mouse button (= pressing the scroll wheel) drag-pans the viewport.
  // Handled on the OUTER full-window Listener so it works anywhere — over the
  // image or the surrounding margins. The draw GestureDetector only claims the
  // primary button, so a middle-drag never draws. Editor-only (gated by wiring).
  void _onMiddleButtonDown(PointerDownEvent e) {
    if ((e.buttons & kMiddleMouseButton) != 0) _middlePanning = true;
  }

  void _onMiddleButtonMove(PointerMoveEvent e) {
    if (_middlePanning && (e.buttons & kMiddleMouseButton) != 0) {
      setState(() => _viewport = _viewport.pannedBy(e.delta));
    }
  }

  void _onMiddleButtonUp(PointerUpEvent e) {
    _middlePanning = false;
  }

  /// The whole-display rect (inset so its frame stays fully on-screen) — the
  /// snap target when hovering bare desktop (no window under the cursor).
  Rect get _fullDisplayRect =>
      Rect.fromLTWH(2, 2, _canvasSize.width - 4, _canvasSize.height - 4);

  /// Tools whose tap snaps to a hovered window's bounds (ShareX-style): crop
  /// captures it; blur/pixelate/rectangle/ellipse add a drawable spanning it.
  static const _snapTools = {
    ToolKind.crop,
    ToolKind.blur,
    ToolKind.pixelate,
    ToolKind.rectangle,
    ToolKind.ellipse,
  };

  /// A drag / edit gesture is in progress (suppresses the window-snap highlight).
  bool get _dragging => _cropping || _dragStart != null || _editIndex != null;

  /// Region-selection tools that get the precision crosshair + pixel loupe (crop
  /// plus the raster regions, where exact alignment on what you obscure matters).
  /// The dimming scrim stays crop-only.
  bool get _showsCrosshair {
    final t = c.tool.value;
    return t == ToolKind.crop || t == ToolKind.blur || t == ToolKind.pixelate;
  }

  @override
  void initState() {
    super.initState();
    // Seed the crosshair at the real cursor (native passes its display-local
    // position on the cursor display), not the display centre.
    final seed = widget.host.cursorSeed;
    _cursor =
        seed ?? Offset(widget.host.size.width / 2, widget.host.size.height / 2);
    _toolbarPos = Offset(
      widget.host.size.width / 2 - 160,
      widget.host.size.height - 60, // dy = toolbar BOTTOM; options grow upward
    );
    _active = widget.host.startsActive; // launch display starts active
    _overCanvas = widget.host.startsActive; // pointer starts over canvas
    _windows = widget.host.snapWindows;
    c.document.addListener(_rebuild);
    c.selectedIndex.addListener(_rebuild);
    c.selectedIndex.addListener(_unpinIfCleared);
    c.tool.addListener(_rebuild);
    c.tool.addListener(_onToolChanged);
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
    c.phase.addListener(_rebuild);
    c.style.addListener(_onStyleChanged);
    _textFocus.addListener(_rebuild); // repaint our selection on focus changes
    widget.host.activeSignal.addListener(
      _onActiveSignal,
    ); // cursor poll drives active
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    c.document.removeListener(_rebuild);
    c.selectedIndex.removeListener(_rebuild);
    c.selectedIndex.removeListener(_unpinIfCleared);
    c.tool.removeListener(_rebuild);
    c.tool.removeListener(_onToolChanged);
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    c.phase.removeListener(_rebuild);
    c.style.removeListener(_onStyleChanged);
    _textFocus.removeListener(_rebuild);
    widget.host.activeSignal.removeListener(_onActiveSignal);
    // Release the whole-frame blur/pixelate native images (created per capture
    // in _ensureRasterFor); otherwise they linger until a GC finalizer runs.
    _blurredFull?.dispose();
    _pixelatedFull?.dispose();
    _textCtl?.dispose();
    _focus.dispose();
    _crop.dispose();
    _textFocus.dispose();
    super.dispose();
  }

  /// While editing, a toolbar style change applies to the whole text box: the
  /// painter (and the transparent field, via build) re-render in the new style.
  void _onStyleChanged() {
    if (_editingText) _rebuild();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _onToolChanged() {
    // Switching tools commits any in-progress text (its tool is gone). Blur no
    // longer commits, so the pt field can take focus without ending editing.
    if (_editingText) _commitText();
    // The "paste" slot is the universal SELECT tool (select / move / resize /
    // delete any drawable). The paste ACTION is Cmd-V only.
    _ensureRasterFor(c.tool.value); // pre-compute whole-frame blur/pixelate
  }

  /// Compute the whole-frame blur / pixelate ONCE when its tool is first
  /// selected (the region drag then just masks it — no per-frame recompute).
  Future<void> _ensureRasterFor(ToolKind t) async {
    // Use the CURRENT canvas image so blur/pixelate align after a crop-trim.
    if (t == ToolKind.blur && _blurredFull == null) {
      final img = await blurWhole(
        _canvasImage,
        kBlurSigmaLogical * widget.host.pixelScale,
      );
      if (mounted) setState(() => _blurredFull = img);
    } else if (t == ToolKind.pixelate && _pixelatedFull == null) {
      final img = await pixelateWhole(_canvasImage, kPixelCellNative);
      if (mounted) setState(() => _pixelatedFull = img);
    }
  }

  @override
  void didUpdateWidget(EditorCore old) {
    super.didUpdateWidget(old);
    // New frozen frame (in-place re-capture) -> the pre-computed images are
    // stale; drop them and recompute for the active tool.
    if (old.host.baseImage != widget.host.baseImage) {
      _blurredFull?.dispose();
      _pixelatedFull?.dispose();
      _blurredFull = null;
      _pixelatedFull = null;
      _windows = widget.host.snapWindows;
      _hoverWindow = null;
      // Re-fit a re-loaded image (interactive editor). Usually moot because the
      // app re-keys EditorCore by ValueKey(image) so a fresh State runs initial
      // fit anyway, but kept correct for in-place baseImage swaps.
      _didInitialFit = false;
      _ensureRasterFor(c.tool.value);
    }
  }

  // ---- cross-display follow (driven by the native cursor poll) -----------

  /// The native poll picked the active display for ALL engines. Become active
  /// when it is us (show the HUD/toolbar, seed the crosshair at the pushed point,
  /// take Flutter keyboard focus); step down when it is another display (hide the
  /// HUD, drop transient draw state). One authoritative signal — no per-engine
  /// guessing or async handoff, so no flicker.
  void _onActiveSignal() {
    final sig = widget.host.activeSignal.value;
    final mine = sig.id == widget.host.hostId;
    if (mine && !_active) {
      setState(() {
        _active = true;
        _cursor = sig.cursor; // land the crosshair where the cursor crossed in
      });
      _focus.requestFocus();
    } else if (!mine && _active) {
      setState(() {
        _active = false;
        _resetDrawState();
        _resetEditState();
      });
    }
  }

  bool _pasting = false; // re-entrancy guard for paste (tool-switch + ⌘V)

  /// Paste a clipboard image as a movable/resizable [ImageDrawable]. No-op when
  /// the clipboard holds no decodable image.
  Future<void> _pasteImage() async {
    if (_pasting) return;
    _pasting = true;
    try {
      final bytes = await Pasteboard.image;
      if (bytes == null || !mounted) return;
      final ui.Image img;
      try {
        final codec = await ui.instantiateImageCodec(bytes);
        img = (await codec.getNextFrame()).image;
      } catch (_) {
        return; // not a decodable image
      }
      if (!mounted) return;
      final sf = widget.host.pixelScale;
      var w = img.width / sf;
      var h = img.height / sf;
      if (w <= 0 || h <= 0) return;
      // Fit within ~half the display, preserving aspect; never upscale.
      final fit = [
        1.0,
        widget.host.size.width * 0.5 / w,
        widget.host.size.height * 0.5 / h,
      ].reduce((a, b) => a < b ? a : b);
      w *= fit;
      h *= fit;
      final rect = Rect.fromCenter(
        center: Offset(widget.host.size.width / 2, widget.host.size.height / 2),
        width: w,
        height: h,
      );
      c.commitDrawable(ImageDrawable(rect, img, c.style.value));
      c.selectTool(ToolKind.paste); // so it can be dragged/resized at once
      c.selectedIndex.value = c.document.value.drawables.length - 1;
    } finally {
      _pasting = false;
    }
  }

  // ---- type filter -------------------------------------------------------

  bool Function(Drawable)? _typeFilter() {
    switch (c.tool.value) {
      case ToolKind.rectangle:
        return (d) => d is RectangleDrawable;
      case ToolKind.ellipse:
        return (d) => d is EllipseDrawable;
      case ToolKind.arrow:
        return (d) => d is ArrowDrawable;
      case ToolKind.line:
        return (d) => d is LineDrawable;
      case ToolKind.pen:
        return (d) => d is PenDrawable;
      case ToolKind.highlighter:
        return (d) => d is HighlighterDrawable;
      case ToolKind.text:
        return (d) => d is TextDrawable;
      case ToolKind.step:
        return (d) => d is StepDrawable;
      case ToolKind.blur:
        return (d) => d is BlurDrawable;
      case ToolKind.pixelate:
        return (d) => d is PixelateDrawable;
      case ToolKind.paste:
        // The "paste" slot is the universal SELECT tool: it operates on EVERY
        // drawable type (select / move / resize / delete), so it matches all.
        return (d) => true;
      case ToolKind.crop:
        return null;
    }
  }

  // Tools whose drawable is a RectShaped region (corner-resizable + drag-create
  // a rectangle): rectangle/ellipse and the raster regions. Paste places via
  // ⌘V rather than a drag, but its drawable is still RectShaped (resizable).
  static const _rectShapeTools = {
    ToolKind.rectangle,
    ToolKind.ellipse,
    ToolKind.blur,
    ToolKind.pixelate,
    ToolKind.paste,
  };

  // Tools whose drawable is a Segmented shape (two endpoint handles, not box
  // corners): line / arrow / highlighter.
  static const _segmentTools = {
    ToolKind.line,
    ToolKind.arrow,
    ToolKind.highlighter,
  };

  int? _hitActiveType(Offset p) =>
      hitTestTop(c.document.value.drawables, p, where: _typeFilter());

  // ---- keyboard ----------------------------------------------------------

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (_editingText) {
      return KeyEventResult.ignored; // text wrapper handles keys
    }
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final key = e.logicalKey;

    if (key == LogicalKeyboardKey.escape) {
      // A gesture in progress -> cancel just that gesture (like a right-click),
      // staying in capture rather than exiting.
      if (_cancelActiveGesture()) return KeyEventResult.handled;
      // Editor trim crop: a pending (drag-released, awaiting-confirm) selection
      // -> clear it.
      if (_inCrop && widget.host.cropTrims && _crop.rect.value != null) {
        setState(() {
          _crop.clear();
          _cropping = false;
        });
        return KeyEventResult.handled;
      }
      widget.host.onCancel();
      return KeyEventResult.handled;
    }

    final pressed = <HotkeyModifier>{
      if (HardwareKeyboard.instance.isMetaPressed) HotkeyModifier.meta,
      if (HardwareKeyboard.instance.isAltPressed) HotkeyModifier.alt,
      if (HardwareKeyboard.instance.isControlPressed) HotkeyModifier.control,
      if (HardwareKeyboard.instance.isShiftPressed) HotkeyModifier.shift,
    };
    // Viewport zoom shortcuts (image editor only): Cmd+1 = fit, Cmd+2 = 100%.
    if (_interactive &&
        pressed.length == 1 &&
        pressed.contains(HotkeyModifier.meta)) {
      if (key == LogicalKeyboardKey.digit1) {
        _refitViewport();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.digit2) {
        _zoomActualSize();
        return KeyEventResult.handled;
      }
    }

    final action = pickEditorAction(e, pressed, widget.editorBindings);
    // While a gesture is in progress, swallow action keys that would desync it
    // (a mid-drag tool switch left e.g. a rectangle drag with crop suddenly
    // active). Esc (cancel) is handled above; the region arrow-nudge below is
    // intentionally still allowed mid-drag.
    if ((_dragging || _cropAdjusting) &&
        (action == kEditorUndoKey ||
            action == kEditorRedoKey ||
            action == kEditorPasteKey ||
            action == kEditorDeleteKey ||
            (action != null && kEditorToolActionKey.containsValue(action)))) {
      return KeyEventResult.handled;
    }
    if (action == kEditorUndoKey) {
      c.undo();
      c.selectedIndex.value = null;
      return KeyEventResult.handled;
    }
    if (action == kEditorRedoKey) {
      c.redo();
      c.selectedIndex.value = null;
      return KeyEventResult.handled;
    }
    if (action == kEditorPasteKey) {
      _pasteImage();
      return KeyEventResult.handled;
    }
    // numpadEnter confirms too, but only while confirm stays on the default
    // Enter binding (HotkeyBinding.matches requires an exact logicalKey, so
    // pickEditorAction never returns confirm for numpadEnter on its own).
    final numpadConfirm =
        e.logicalKey == LogicalKeyboardKey.numpadEnter &&
        widget.editorBindings[kEditorConfirmKey]?.logicalKey ==
            LogicalKeyboardKey.enter;
    if ((action == kEditorConfirmKey || numpadConfirm) && !_dragging) {
      if (widget.host.cropTrims) {
        // Image editor: Enter confirms a pending crop-trim; otherwise it does
        // nothing (Complete is the explicit Save / Copy buttons, never Enter).
        if (c.tool.value == ToolKind.crop && _crop.rect.value != null) {
          _confirmTrim();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      }
      // Overlay: Confirm/Export is always a SCREENSHOT — never the tool's own
      // click effect (so in blur/pixelate it screenshots rather than applies the
      // effect). Skipped mid-gesture (a drag/edit in progress).
      if (_showsCrosshair) {
        // Crosshair/loupe tools (crop/blur/pixelate + any future ones): capture
        // the snap target — the window under the cursor, or the whole display
        // when none is under it.
        final win = topmostWindowAt(_windows, _cursor);
        widget.host.onExport(win?.rect, win);
      } else {
        // Other tools: export the whole (annotated) display.
        widget.host.onExport(null, topmostWindowAt(_windows, _cursor));
      }
      return KeyEventResult.handled;
    }
    if (action == kEditorDeleteKey && c.selectedIndex.value != null) {
      c.deleteSelected();
      return KeyEventResult.handled;
    }
    if (action != null && kEditorToolActionKey.containsValue(action)) {
      final tool = kEditorToolActionKey.entries
          .firstWhere((x) => x.value == action)
          .key;
      c.selectTool(tool);
      return KeyEventResult.handled;
    }

    // Arrow-nudge for the region tools (crop + blur/pixelate): move the crosshair
    // by ONE PHYSICAL pixel (= 1 / scaleFactor logical points — a single pixel on
    // Retina, not 2-3) and warp the OS cursor to match so a later physical move
    // continues from the nudged point. Also nudges the in-progress region's
    // dragging corner.
    if (_showsCrosshair) {
      final step = 1.0 / widget.host.pixelScale;
      Offset? delta;
      if (key == LogicalKeyboardKey.arrowLeft) delta = Offset(-step, 0);
      if (key == LogicalKeyboardKey.arrowRight) delta = Offset(step, 0);
      if (key == LogicalKeyboardKey.arrowUp) delta = Offset(0, -step);
      if (key == LogicalKeyboardKey.arrowDown) delta = Offset(0, step);
      if (delta != null) {
        final next = Offset(
          (_cursor.dx + delta.dx).clamp(0.0, _canvasSize.width),
          (_cursor.dy + delta.dy).clamp(0.0, _canvasSize.height),
        );
        final s = _dragStart;
        setState(() {
          _cursor = next;
          if (s != null && c.tool.value == ToolKind.blur) {
            _preview = BlurDrawable(Rect.fromPoints(s, next), c.style.value);
          } else if (s != null && c.tool.value == ToolKind.pixelate) {
            _preview = PixelateDrawable(
              Rect.fromPoints(s, next),
              c.style.value,
            );
          }
        });
        if (c.tool.value == ToolKind.crop && _cropping) _crop.update(next);
        widget.host.cursor.warp(
          widget.host.globalOrigin.dx + next.dx,
          widget.host.globalOrigin.dy + next.dy,
        );
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _onTextKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.enter ||
        e.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        return KeyEventResult.ignored; // Shift+Enter -> newline
      }
      _commitText();
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      _cancelText();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ---- text editing ------------------------------------------------------

  void _startText(Offset at) {
    final ctl = TextEditingController()..addListener(_rebuild);
    setState(() {
      _textCtl = ctl;
      _editTextIndex = null;
      _textPos = at;
      _editingText = true;
      c.selectedIndex.value = null;
    });
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _textFocus.requestFocus(),
    );
  }

  void _reEditText(int idx) {
    final d = c.document.value.drawables[idx];
    if (d is! TextDrawable) return;
    // Reflect the box's own style in the toolbar so the size / family / colour
    // controls show the text being edited (single style per box).
    c.style.value = d.style;
    final ctl = TextEditingController(text: d.text)..addListener(_rebuild);
    setState(() {
      _textCtl = ctl;
      _editTextIndex = idx;
      _textPos = d.position;
      _editingText = true;
      c.selectedIndex.value = null;
    });
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _textFocus.requestFocus(),
    );
  }

  void _commitText() {
    final pos = _textPos;
    final ctl = _textCtl;
    final idx = _editTextIndex;
    if (pos != null && ctl != null) {
      if (ctl.text.trim().isNotEmpty) {
        final d = TextDrawable(pos, ctl.text, c.style.value);
        c.document.value = idx != null
            ? c.document.value.replaceAt(idx, d)
            : c.document.value.add(d);
      } else if (idx != null) {
        c.document.value = c.document.value.removeAt(idx); // edited to empty
      }
    }
    _cancelText();
  }

  void _cancelText() {
    final old = _textCtl;
    old?.removeListener(_rebuild);
    setState(() {
      _editingText = false;
      _textPos = null;
      _editTextIndex = null;
      _textCtl = null;
    });
    // Dispose after this frame so the now-removed TextField doesn't touch a
    // disposed controller.
    WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
    _focus.requestFocus();
  }

  // ---- pointer gestures --------------------------------------------------

  List<Offset> _rectCorners(Rect r) => [
    r.topLeft,
    r.topRight,
    r.bottomRight,
    r.bottomLeft,
  ];

  bool _nearHandles(Drawable d, Offset p) {
    if (d is RectShaped) {
      for (final corner in _rectCorners((d as RectShaped).rect.inflate(4))) {
        if ((corner - p).distance <= 16) return true;
      }
    }
    return d.bounds.inflate(8).contains(p);
  }

  // Left-click PINS the selection: a clicked annotation stays selected even when
  // the cursor leaves it (e.g. to reach the option bar to restyle it). Hover only
  // previews a selection while nothing is pinned; clicking empty space unpins.
  bool _pinned = false;

  void _selectAndPin(int? idx) {
    c.selectedIndex.value = idx;
    _pinned = idx != null;
  }

  // Any deselection (undo/redo, delete, tool switch, capture reset, empty click)
  // also drops the pin so hover-preview resumes.
  void _unpinIfCleared() {
    if (c.selectedIndex.value == null) _pinned = false;
  }

  void _onHover(PointerHoverEvent e) {
    final p = _toLogical(e.localPosition);
    setState(() => _cursor = p);
    if (_inCrop) return;
    if (_pinned) return; // a pinned (clicked) selection ignores hover changes
    final drawables = c.document.value.drawables;
    final cur = c.selectedIndex.value;
    // Keep the current selection while hovering its handle/edge zone so the
    // handles stay visible and grabbable (they sit just outside the shape).
    if (cur != null &&
        cur < drawables.length &&
        _nearHandles(drawables[cur], p)) {
      return;
    }
    final idx = _hitActiveType(p); // highlight same-type drawable under cursor
    if (cur != idx) c.selectedIndex.value = idx;
  }

  void _onTapUp(TapUpDetails d) {
    if (_editingText) {
      _commitText();
      return;
    }
    final p = _toLogical(d.localPosition);
    // Window-snap (ShareX-style): a tap on a window applies the snap tool to that
    // window's bounds — crop captures it; blur/pixelate/rectangle/ellipse add a
    // drawable spanning it. With NO window under the cursor the tools fall back
    // to their normal tap (crop -> whole display; the rest select).
    final win = topmostWindowAt(_windows, p);
    final style = c.style.value;
    switch (c.tool.value) {
      case ToolKind.crop:
        // Editor: crop is drag-to-trim (then Enter/✔ confirms); a bare tap does
        // nothing. Overlay: a tap captures the snapped window / whole display.
        if (widget.host.cropTrims) return;
        widget.host.onExport(win?.rect, win); // null window -> whole display
        return;
      // For the snap tools, selecting an existing same-type region WINS over
      // snapping a new one — so you can click a committed region to re-select /
      // restyle it even when it sits over a window. No hit + a window under the
      // cursor -> snap a new region; nothing at all -> deselect.
      case ToolKind.blur:
        if (_hitActiveType(p) case final hit?) {
          _selectAndPin(hit);
        } else if (win != null) {
          c.commitDrawable(BlurDrawable(win.rect, style));
        } else {
          _selectAndPin(null);
        }
        return;
      case ToolKind.pixelate:
        if (_hitActiveType(p) case final hit?) {
          _selectAndPin(hit);
        } else if (win != null) {
          c.commitDrawable(PixelateDrawable(win.rect, style));
        } else {
          _selectAndPin(null);
        }
        return;
      case ToolKind.rectangle:
        if (_hitActiveType(p) case final hit?) {
          _selectAndPin(hit);
        } else if (win != null) {
          c.commitDrawable(RectangleDrawable(win.rect, style));
        } else {
          _selectAndPin(null);
        }
        return;
      case ToolKind.ellipse:
        if (_hitActiveType(p) case final hit?) {
          _selectAndPin(hit);
        } else if (win != null) {
          c.commitDrawable(EllipseDrawable(win.rect, style));
        } else {
          _selectAndPin(null);
        }
        return;
      case ToolKind.text:
        final idx = _hitActiveType(p);
        idx != null ? _reEditText(idx) : _startText(p);
        return;
      case ToolKind.step:
        // Tap on empty space places a new auto-numbered badge; tap on an
        // existing badge just selects it (drag the body to move).
        final idx = _hitActiveType(p);
        if (idx == null) {
          c.commitDrawable(
            StepDrawable(p, nextStepNumber(c.document.value.drawables), style),
          );
        } else {
          _selectAndPin(idx);
        }
        return;
      case ToolKind.arrow:
      case ToolKind.line:
      case ToolKind.pen:
      case ToolKind.highlighter:
      case ToolKind.paste:
        _selectAndPin(_hitActiveType(p));
        return;
    }
  }

  bool _rightLatched = false; // right button currently held (handled once)

  /// Fire [_onRightDown] once when the secondary button goes down, whether it
  /// arrives as a fresh down or mid-drag as a move; reset when it releases.
  void _onPointerButtons(PointerEvent e) {
    final right = (e.buttons & kSecondaryButton) != 0;
    if (right && !_rightLatched) {
      _rightLatched = true;
      _onRightDown(_toLogical(e.localPosition));
    } else if (!right) {
      _rightLatched = false;
    }
  }

  /// Track the crosshair from the raw pointer stream (outermost Listener), so it
  /// follows everywhere on the active display — over the toolbar, and while the
  /// left button is still held after a right-click cancel.
  void _trackCursor(PointerEvent e) {
    if (!_active) return;
    final p = _toLogical(e.localPosition);
    // Window-snap: highlight the top-most window under the cursor for the snap
    // tools (crop/blur/pixelate/rectangle/ellipse), but not while dragging. The
    // full-screen crosshair / reticle follow the pointer on the active display.
    final hover = (_snapTools.contains(c.tool.value) && !_dragging)
        ? topmostWindowAt(_windows, p)
        : null;
    setState(() {
      _cursor = _clampToDisplay(p);
      _hoverWindow = hover?.rect;
    });
  }

  /// The universal SELECT tool (the repurposed "paste" slot): operates on any
  /// drawable type. It shows the normal arrow cursor — neither crosshair (region
  /// tools) nor our drawing reticle.
  bool get _isSelectTool => c.tool.value == ToolKind.paste;

  /// True when our small reticle should show: an active DRAWING tool (not a
  /// region tool, which uses the full crosshair; not the select tool, which uses
  /// the system arrow) with the pointer over the canvas and no text edit.
  bool get _showsReticle =>
      _active &&
      !_showsCrosshair &&
      !_isSelectTool &&
      _overCanvas &&
      !_editingText;

  /// Hide the system cursor whenever we're drawing OUR own cursor (crosshair or
  /// reticle) over the canvas, or while dragging (the drag may briefly stray off
  /// the display before the confine warps it back). Show it over the toolbar and
  /// while editing text. Only the active engine drives the (app-global) state;
  /// pushed on change. Called from build so any setState reconciles it.
  void _syncCursorHidden() {
    final hide =
        _active &&
        !_editingText &&
        !_isSelectTool && // select shows the system arrow, never hidden
        (_overCanvas || _dragStart != null || _editIndex != null || _cropping);
    if (hide != _lastHide) {
      _lastHide = hide;
      widget.host.cursor.setHidden(hide);
    }
  }

  /// Clamp a position to this display's bounds. During a drag the (hidden)
  /// hardware cursor can wander onto another display — we freeze the cross-display
  /// handoff natively rather than warp the cursor each frame (which jittered), so
  /// clamping keeps the crosshair / marquee pinned cleanly at the edge.
  Offset _clampToDisplay(Offset p) => Offset(
    p.dx.clamp(0.0, _canvasSize.width),
    p.dy.clamp(0.0, _canvasSize.height),
  );

  /// Cancel an in-progress gesture (crop/draw/move/resize/endpoint) WITHOUT
  /// leaving capture: revert it, release the cursor confine, and flag the pending
  /// pan-end so it won't commit. Returns true if a gesture was cancelled. Shared
  /// by right-click and Esc.
  bool _cancelActiveGesture() {
    if (!(_cropping ||
        _dragStart != null ||
        _preview != null ||
        _editIndex != null)) {
      return false;
    }
    widget.host.cursor.setDrawingLock(false); // release the cursor confine
    setState(() {
      _cancelGesture = true; // a pending pan-end must not commit
      _crop.clear();
      _cropping = false;
      _resetDrawState();
      _resetEditState();
    });
    return true;
  }

  void _onRightDown(Offset p) {
    // While editing text, right-click just commits the in-progress text — it
    // does NOT delete/exit, which would discard the unfinished text.
    if (_editingText) {
      _commitText();
      return;
    }
    // Right-click is contextual (priority order):
    //  1) a gesture in progress -> CANCEL it (crop drag clears the selection; a
    //     draw / move / resize reverts), stay in capture;
    //  2) over a SAME-TYPE drawable (the active tool only deletes its own type,
    //     mirroring left-click selection) -> DELETE it, stay;
    //  3) otherwise -> EXIT the capture, like Esc (nothing of the active tool's
    //     type is under the cursor, so for that tool the spot is "empty").
    if (_cancelActiveGesture()) return;
    // Crop (and any tool with no own drawable type: _typeFilter() == null) never
    // deletes — right-click falls through to exit, over a drawable or empty space
    // alike. For a tool WITH a type, prefer the drawable whose handles are showing:
    // if a same-type drawable is selected and the cursor is still in its handle /
    // edge zone (the SAME generous test `_onHover` uses to keep the handles
    // visible), delete THAT one — matching the visual affordance — else the strict
    // same-type hit. A selection left over from a previous tool won't match.
    final filter = _typeFilter();
    int? idx;
    if (filter != null) {
      final drawables = c.document.value.drawables;
      final cur = c.selectedIndex.value;
      idx =
          (cur != null &&
              cur < drawables.length &&
              filter(drawables[cur]) &&
              _nearHandles(drawables[cur], p))
          ? cur
          : _hitActiveType(p);
    }
    if (idx != null) {
      c.document.value = c.document.value.removeAt(idx);
      c.selectedIndex.value = null;
      return;
    }
    // Nothing of the active tool's type here -> exit, unless the user disabled
    // right-click-to-exit in settings (Esc still exits regardless).
    if (widget.host.rightClickExits) widget.host.onCancel();
  }

  void _resetDrawState() {
    _preview = null;
    _dragStart = null;
    _strokePoints = null;
    _cropCorner = null;
    _cropMoveStart = null;
    _cropMoveOrigin = null;
  }

  void _resetEditState() {
    _editIndex = null;
    _editOriginal = null;
    _editPreview = null;
    _moveStart = null;
    _resizeCorner = null;
    _endpoint = null;
  }

  // Re-apply the active drag's constraint when Shift is pressed/released MID-drag
  // without moving the mouse — no pointer event fires, so the preview would
  // otherwise not refresh until the next move. Observe-only (returns false).
  bool _onHardwareKey(KeyEvent e) {
    if (e is KeyRepeatEvent) return false;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.shiftLeft || k == LogicalKeyboardKey.shiftRight) {
      final p = _dragPos;
      if (p != null && (_dragging || _cropAdjusting)) _applyDrag(p);
    }
    return false;
  }

  void _panStart(DragStartDetails d) {
    _cancelGesture = false;
    // A drag begins: confine the cursor to this display so the stroke can't be
    // broken by the pointer straying onto another display (released in _panEnd /
    // _panCancel). Spanning across displays is out of scope.
    widget.host.cursor.setDrawingLock(true);
    final p = _toLogical(d.localPosition);
    // The editor has no outer pointer tracker (the overlay uses _trackCursor on
    // the full-window Listener), so the reticle/crosshair must advance from the
    // pan stream here — otherwise it freezes at the drag's start point.
    if (_interactive) setState(() => _cursor = p);
    if (c.tool.value == ToolKind.crop) {
      // Editor: with a pending selection, a press on a corner resizes it and a
      // press inside moves it; elsewhere starts a fresh selection.
      final pending = widget.host.cropTrims ? _crop.rect.value : null;
      if (pending != null) {
        final tol = 16 / _viewport.scale; // ~16 screen px regardless of zoom
        final corners = _rectCorners(pending);
        for (var ci = 0; ci < corners.length; ci++) {
          if ((corners[ci] - p).distance <= tol) {
            _cropCorner = ci;
            setState(() => _cursor = p);
            return;
          }
        }
        if (pending.contains(p)) {
          _cropMoveStart = p;
          _cropMoveOrigin = pending;
          setState(() => _cursor = p);
          return;
        }
      }
      _cropping = true;
      setState(() {
        _cursor = p;
        _hoverWindow = null;
      });
      _crop.begin(p);
      return;
    }
    final drawables = c.document.value.drawables;
    // Rect-shape corner-resize (rectangle/ellipse): check every same-type shape's
    // corners (topmost first) with a generous tolerance, independent of the
    // current hover selection.
    final filter = _typeFilter();
    if (_rectShapeTools.contains(c.tool.value)) {
      for (var idx = drawables.length - 1; idx >= 0; idx--) {
        final d = drawables[idx];
        if (d is! RectShaped || (filter != null && !filter(d))) continue;
        final corners = _rectCorners((d as RectShaped).rect.inflate(4));
        for (var ci = 0; ci < corners.length; ci++) {
          if ((corners[ci] - p).distance <= 16) {
            _editIndex = idx;
            _editOriginal = drawables[idx];
            _editPreview = drawables[idx];
            _resizeCorner = ci;
            c.selectedIndex.value = idx;
            _pinned = true; // dragging an existing shape pins it
            return;
          }
        }
      }
    }
    // Segment endpoint-drag (line/arrow/highlighter): a press near a start/end
    // handle moves just that endpoint; a press on the body falls through to move.
    if (_segmentTools.contains(c.tool.value)) {
      for (var idx = drawables.length - 1; idx >= 0; idx--) {
        final d = drawables[idx];
        if (d is! Segmented || (filter != null && !filter(d))) continue;
        final ends = [(d as Segmented).start, (d as Segmented).end];
        for (var ei = 0; ei < ends.length; ei++) {
          if ((ends[ei] - p).distance <= 16) {
            _editIndex = idx;
            _editOriginal = drawables[idx];
            _editPreview = drawables[idx];
            _endpoint = ei;
            c.selectedIndex.value = idx;
            _pinned = true; // dragging an endpoint pins the shape
            return;
          }
        }
      }
    }
    final hit = _hitActiveType(p);
    if (hit != null) {
      _editIndex = hit;
      _editOriginal = drawables[hit];
      _editPreview = drawables[hit];
      _moveStart = p;
      _resizeCorner = null;
      c.selectedIndex.value = hit;
      _pinned = true; // dragging an existing shape pins it
    } else {
      // Starting a fresh drawing drops any pinned selection.
      _selectAndPin(null);
      _dragStart = p; // start drawing a new same-type drawable (not for text)
      _preview = null;
      // Pen accumulates the stroke's points as the drag proceeds.
      if (c.tool.value == ToolKind.pen) _strokePoints = [p];
    }
  }

  void _panUpdate(DragUpdateDetails d) {
    // Map to logical first. The overlay clamps to the display so the marquee /
    // shape stays pinned at the boundary. The editor lets a DRAWING / MOVE run
    // past the image edge (it is masked on screen + clipped on export), but keeps
    // the CROP selection inside the image.
    final logical = _toLogical(d.localPosition);
    final p = (_interactive && c.tool.value != ToolKind.crop)
        ? logical
        : _clampToDisplay(logical);
    _applyDrag(p);
  }

  // Apply the drag at logical position [p]. Saved as [_dragPos] so a mid-drag
  // Shift press/release (which produces no pointer event) can re-run the same
  // constraint at the same point — see [_onHardwareKey].
  void _applyDrag(Offset p) {
    _dragPos = p;
    if (_cancelGesture) {
      // Right-click cancelled this drag: keep the crosshair tracking the mouse
      // while the left button is still held (no jank if the two buttons aren't
      // released together); a new selection needs a fresh left press.
      if (_showsCrosshair) setState(() => _cursor = p);
      return;
    }
    // Editor: advance the reticle/crosshair from the pan stream for EVERY tool
    // (no outer tracker); the crop/blur/pixelate branches below also keep it.
    if (_interactive) setState(() => _cursor = p);
    if (c.tool.value == ToolKind.crop) {
      // Editor: resize a pending selection from its grabbed corner, or move the
      // whole rect; otherwise extend the in-progress selection. Shift squares the
      // resize / draw (capped to the canvas), like a rectangle drag.
      final shift = HardwareKeyboard.instance.isShiftPressed;
      if (_cropCorner != null) {
        final cur = _crop.rect.value;
        if (cur != null) {
          final opposite = _rectCorners(cur)[(_cropCorner! + 2) % 4];
          final cp = shift ? _squareCornerIn(opposite, p, _canvasSize) : p;
          _crop.set(Rect.fromPoints(opposite, cp));
        }
      } else if (_cropMoveStart != null && _cropMoveOrigin != null) {
        _crop.set(_cropMoveOrigin!.shift(p - _cropMoveStart!));
      } else {
        final a = _crop.anchor;
        final to = (shift && a != null) ? _squareCornerIn(a, p, _canvasSize) : p;
        _crop.update(to);
      }
      setState(() => _cursor = p);
      return;
    }
    if (_editIndex != null) {
      _updateSelectDrag(p);
      return;
    }
    final s = _dragStart;
    if (s == null) return;
    // Shift constrains the drag: box tools -> square (circle for the ellipse),
    // two-point tools -> snap to the nearest of 8 directions.
    final shift = HardwareKeyboard.instance.isShiftPressed;
    switch (c.tool.value) {
      case ToolKind.rectangle:
        final cp = shift ? _squareCorner(s, p) : p;
        setState(
          () =>
              _preview = RectangleDrawable(Rect.fromPoints(s, cp), c.style.value),
        );
        break;
      case ToolKind.ellipse:
        final cp = shift ? _squareCorner(s, p) : p;
        setState(
          () => _preview = EllipseDrawable(Rect.fromPoints(s, cp), c.style.value),
        );
        break;
      case ToolKind.arrow:
        final cp = shift ? _snap8(s, p) : p;
        setState(() => _preview = ArrowDrawable(s, cp, c.style.value));
        break;
      case ToolKind.line:
        final cp = shift ? _snap8(s, p) : p;
        setState(() => _preview = LineDrawable(s, cp, c.style.value));
        break;
      case ToolKind.highlighter:
        // Straight marker swipe: a 2-point band from the drag start to here.
        final cp = shift ? _snap8(s, p) : p;
        setState(() => _preview = HighlighterDrawable([s, cp], c.style.value));
        break;
      case ToolKind.pen:
        _strokePoints = [...?_strokePoints, p];
        setState(() => _preview = PenDrawable(_strokePoints!, c.style.value));
        break;
      case ToolKind.blur:
        final cp = shift ? _squareCorner(s, p) : p;
        setState(() {
          _cursor = p; // keep the crosshair/loupe on the dragging corner
          _preview = BlurDrawable(Rect.fromPoints(s, cp), c.style.value);
        });
        break;
      case ToolKind.pixelate:
        final cp = shift ? _squareCorner(s, p) : p;
        setState(() {
          _cursor = p;
          _preview = PixelateDrawable(Rect.fromPoints(s, cp), c.style.value);
        });
        break;
      case ToolKind.text:
      case ToolKind.step:
      case ToolKind.paste:
      case ToolKind.crop:
        break;
    }
  }

  void _updateSelectDrag(Offset p) {
    final orig = _editOriginal;
    if (orig == null) return;
    // Shift constrains an edit drag too: endpoint -> 8 directions from the fixed
    // end; corner-resize -> square (circle) from the opposite corner.
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (_endpoint != null && orig is Segmented) {
      final seg = orig as Segmented;
      final anchor = _endpoint == 0 ? seg.end : seg.start; // the fixed end
      final moved = shift ? _snap8(anchor, p) : p;
      final start = _endpoint == 0 ? moved : seg.start;
      final end = _endpoint == 1 ? moved : seg.end;
      setState(() => _editPreview = seg.withEndpoints(start, end));
    } else if (_resizeCorner != null && orig is RectShaped) {
      final shape = orig as RectShaped;
      final corners = _rectCorners(shape.rect);
      final opposite = corners[(_resizeCorner! + 2) % 4];
      final cp = shift ? _squareCorner(opposite, p) : p;
      setState(
        () => _editPreview = shape.resizedTo(Rect.fromPoints(opposite, cp)),
      );
    } else {
      final start = _moveStart;
      if (start != null) {
        setState(() => _editPreview = orig.moved(p - start));
      }
    }
  }

  void _panEnd(DragEndDetails d) {
    widget.host.cursor.setDrawingLock(
      false,
    ); // drag finished -> release the cursor confine
    if (_cancelGesture) {
      _cancelGesture = false;
      setState(() {
        _resetDrawState();
        _resetEditState();
      });
      return;
    }
    if (c.tool.value == ToolKind.crop) {
      _cropping = false;
      _cropCorner = null;
      _cropMoveStart = null;
      _cropMoveOrigin = null;
      final r = _crop.rect.value;
      final valid = r != null && r.width >= 2 && r.height >= 2;
      if (widget.host.cropTrims) {
        // Editor: leave a VALID selection pending (scrim + handles + ✔/✖ shown;
        // Enter/✔ trims, Esc/✖ cancels); discard a too-small one. Rebuild so the
        // pending-state HUD (handles + confirm buttons) appears.
        if (!valid) setState(() => _crop.clear());
        setState(() {});
        return;
      }
      if (valid) {
        // Overlay: the drag-release commits the export-region. Window under the
        // cursor at the release point names the file.
        widget.host.onExport(r, topmostWindowAt(_windows, _cursor));
      } else {
        setState(() => _crop.clear());
      }
      return;
    }
    if (_editIndex != null) {
      final i = _editIndex!;
      final prev = _editPreview;
      setState(_resetEditState);
      // One undo step = the move/resize. Blur/pixelate just mask the shared
      // whole-frame image, so a moved/resized region is correct immediately.
      if (prev != null) c.document.value = c.document.value.replaceAt(i, prev);
      return;
    }
    final prev = _preview;
    setState(_resetDrawState);
    if (prev != null && prev.bounds.longestSide >= 3) c.commitDrawable(prev);
  }

  // ---- build -------------------------------------------------------------

  List<Drawable> _effectiveDrawables() {
    var list = [...c.document.value.drawables];
    final i = _editIndex;
    final prev = _editPreview;
    if (i != null && prev != null && i < list.length) list[i] = prev;
    if (_preview != null) list.add(_preview!);
    // While editing, the TextField text is transparent (caret only) and WE paint
    // the live text via the painter — so what's shown is always the final
    // rendering (zero shift on commit). New text appends; a re-edit replaces in
    // place.
    if (_editingText && _textPos != null && _textCtl != null) {
      final live = TextDrawable(_textPos!, _textCtl!.text, c.style.value);
      final t = _editTextIndex;
      if (t != null && t < list.length) {
        list[t] = live;
      } else {
        list = [...list, live];
      }
    }
    return list;
  }

  void _moveToolbar(Offset delta) {
    setState(() {
      _toolbarPos = Offset(
        (_toolbarPos.dx + delta.dx).clamp(0.0, widget.host.size.width - 80),
        // dy is the toolbar's bottom edge; keep it on-screen with the tool row
        // visible (>= 80 from the top) down to the screen bottom.
        (_toolbarPos.dy + delta.dy).clamp(80.0, widget.host.size.height),
      );
    });
  }

  /// Loupe placement for the OVERLAY (clamped within the display, flipping near
  /// the bottom/right edges). The editor positions its loupe in screen space
  /// (see [_editorLoupe]) so it can float over the checkerboard margin.
  Offset _loupeOrigin() {
    const size = 120.0;
    const gap = 24.0;
    var lx = _cursor.dx + gap;
    var ly = _cursor.dy + gap;
    if (lx + size > _canvasSize.width) lx = _cursor.dx - gap - size;
    if (ly + size > _canvasSize.height) ly = _cursor.dy - gap - size;
    // After a crop-trim the canvas can be smaller than the loupe; guard the
    // upper clamp bound so it never goes negative (clamp throws if min > max).
    final maxX = (_canvasSize.width - size).clamp(0.0, double.infinity);
    final maxY = (_canvasSize.height - size).clamp(0.0, double.infinity);
    return Offset(lx.clamp(0.0, maxX), ly.clamp(0.0, maxY));
  }

  /// The annotation layer, masked to the image rect for the editor (so a drawing
  /// dragged past the edge is hidden + clipped on export) and left unwrapped for
  /// the overlay (full-screen, structurally identical).
  Widget _annotationLayer(bool inCrop) {
    final layer = CustomPaint(
      painter: DrawablePainter(
        // Annotations always paint (so an inactive display still shows its
        // drawings); only the selection highlight is gated on focus.
        drawables: _effectiveDrawables(),
        selectedIndex: (!_active || inCrop || _editingText)
            ? null
            : c.selectedIndex.value,
        blurredFull: _blurredFull,
        pixelatedFull: _pixelatedFull,
      ),
      size: _canvasSize,
    );
    return _interactive ? ClipRect(child: layer) : layer;
  }

  /// The editor's pixel loupe, positioned in SCREEN space at the cursor's
  /// bottom-right (flipping near the window edges so it stays on-screen). It can
  /// float over the checkerboard margin; the content magnifies the canvas around
  /// the logical cursor.
  Widget _editorLoupe(EditorViewport v) {
    const size = 120.0, gap = 24.0;
    final cs = v.toLocal(_cursor); // cursor in screen coords
    var lx = cs.dx + gap;
    var ly = cs.dy + gap;
    if (lx + size > _lastBoxSize.width) lx = cs.dx - gap - size;
    if (ly + size > _lastBoxSize.height) ly = cs.dy - gap - size;
    return Positioned(
      left: lx,
      top: ly,
      child: IgnorePointer(
        child: CustomPaint(
          size: const Size(size, size),
          painter: LoupePainter(
            image: _canvasImage,
            cursorLogical: _cursor,
            scaleFactor: widget.host.pixelScale,
            drawables: _effectiveDrawables(),
            blurredFull: _blurredFull,
            pixelatedFull: _pixelatedFull,
            logicalSize: _canvasSize,
          ),
        ),
      ),
    );
  }

  /// The ✔/✖ confirm bar for a pending crop-trim, positioned just below the
  /// selection's on-screen (viewport-mapped) bottom-right and clamped on-screen.
  Widget _cropConfirmButtons(EditorViewport v) {
    final r = _crop.rect.value!;
    final screenLeft = v.offset.dx + r.left * v.scale;
    final screenTop = v.offset.dy + r.top * v.scale;
    final w = r.width * v.scale;
    final h = r.height * v.scale;
    const barW = 80.0, barH = 40.0, gap = 8.0;
    return Positioned(
      left: (screenLeft + w - barW).clamp(gap, _lastBoxSize.width - barW - gap),
      top: (screenTop + h + gap).clamp(gap, _lastBoxSize.height - barH - gap),
      child: _CropConfirmBar(
        onConfirm: _confirmTrim,
        onCancel: () => setState(() {
          _crop.clear();
          _cropping = false;
        }),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _syncCursorHidden(); // reconcile system-cursor visibility (pushed on change)
    // Let a docked host toolbar drive Fit / 100% (image editor). Rebound each
    // build so the currently-mounted State always owns the handlers.
    final vc = widget.viewportController;
    if (vc != null) {
      vc.onFit = _refitViewport;
      vc.onActualSize = _zoomActualSize;
    }
    final inCrop = _inCrop;
    final showsCrosshair = _showsCrosshair;
    final loupeOrigin = _loupeOrigin();
    // The precision crosshair + loupe show on the active display. For the editor
    // they ALSO require the cursor to be over the image (or mid-gesture): off the
    // image they hide instead of freezing at the edge. The overlay is full-screen,
    // so this is always satisfied there.
    final showHud =
        _active &&
        showsCrosshair &&
        (!_interactive || _overCanvas || _dragging || _cropAdjusting);
    // Window-snap target: the hovered window, or — Crop only — the whole display
    // over bare desktop; null when no snap tool is active or while dragging.
    final snapTarget =
        (_active && _snapTools.contains(c.tool.value) && !_dragging)
        ? (_hoverWindow ??
              // Whole-display crop fallback is an overlay affordance only; the
              // editor's crop is a freeform drag (no window list to snap to).
              (!_interactive && c.tool.value == ToolKind.crop
                  ? _fullDisplayRect
                  : null))
        : null;
    // Outermost listener tracks the cursor for the crosshair from the RAW
    // pointer stream — fires everywhere (incl. over the toolbar, and after a
    // right-click ends the pan), so the crosshair follows continuously on the
    // active display. WHICH display is active is decided by the native cursor
    // poll (_onActiveSignal), not by enter/exit here.
    return Listener(
      // The overlay tracks the cursor here (full-screen crosshair); the editor's
      // crosshair/reticle is driven by the image-rect gesture layer's onHover, so
      // the outer tracker is overlay-only.
      onPointerHover: _interactive ? null : _trackCursor,
      // Editor: middle-button (wheel-press) drag-pan on the full-window stream;
      // overlay: the cursor tracker. (A middle move with no middle button held
      // is a no-op, so this never interferes with drawing.)
      onPointerMove: _interactive ? _onMiddleButtonMove : _trackCursor,
      onPointerDown: _interactive ? _onMiddleButtonDown : null,
      onPointerUp: _interactive ? _onMiddleButtonUp : null,
      // Zoom/pan signals (image editor only): scroll = pan, Cmd+scroll = zoom,
      // trackpad pinch = zoom. The overlay passes null (no viewport).
      onPointerSignal: _interactive ? _onPointerSignal : null,
      onPointerPanZoomStart: _interactive ? _onPanZoomStart : null,
      onPointerPanZoomUpdate: _interactive ? _onPanZoomUpdate : null,
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final box = constraints.biggest;
            _lastBoxSize = box; // read later by _refitViewport (no setState)
            // Fit-to-window once per loaded image: only for the interactive
            // editor (the overlay stays at identity). Assigned during build (the
            // new viewport is consumed immediately by the matrix below), never
            // via setState.
            if (_interactive &&
                !_didInitialFit &&
                box.isFinite &&
                box.width > 0 &&
                box.height > 0) {
              _viewport = _fittedViewport(box);
              _didInitialFit = true;
            }
            // Gesture + hover layer. A Listener catches the right button reliably
            // even mid-drag (GestureDetector's secondary-tap loses the arena to an
            // active pan), so right-click can cancel an in-progress crop/draw.
            // Stable key so its pan recognizer is never re-created mid-drag.
            // For the EDITOR this is placed at BOX level (a sibling of the
            // viewport-transformed painters), so its hit region always covers the
            // window; for the OVERLAY it sits inside the stack at its original spot.
            final gestureLayer = Listener(
              onPointerDown: _onPointerButtons,
              onPointerMove: _onPointerButtons,
              onPointerUp: _onPointerButtons,
              child: MouseRegion(
                cursor: (_active && !_editingText && !_isSelectTool)
                    ? SystemMouseCursors.none
                    : SystemMouseCursors.basic,
                onEnter: (_) => setState(() => _overCanvas = true),
                onExit: (_) => setState(() => _overCanvas = false),
                onHover: _onHover,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  // Editor: exclude trackpad so a two-finger pan/pinch zooms (handled
                  // on the outer Listener) instead of being claimed as a draw drag.
                  supportedDevices: _interactive ? _kDrawDevices : null,
                  onTapUp: _onTapUp,
                  onPanStart: _panStart,
                  onPanUpdate: _panUpdate,
                  onPanEnd: _panEnd,
                  onPanCancel: () {
                    widget.host.cursor.setDrawingLock(false);
                    _cancelGesture = false;
                    setState(() {
                      _resetDrawState();
                      _resetEditState();
                      _cropping = false;
                    });
                  },
                ),
              ),
            );
            final stack = Stack(
              fit: StackFit.expand,
              children: [
                // Layer 1: frozen image (full color, no dim in the annotate phase).
                // The overlay paints it plain full-screen; the image editor gives it
                // a rounded border + drop shadow on the checkerboard (owner's image
                // card), sized to the logical canvas inside the viewport transform.
                RepaintBoundary(
                  child: _interactive
                      ? Container(
                          width: _canvasSize.width,
                          height: _canvasSize.height,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: const Color(
                                0x14FFFFFF,
                              ), // rgba(255,255,255,0.08)
                            ),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x8C000000), // rgba(0,0,0,0.55)
                                blurRadius: 70,
                                offset: Offset(0, 30),
                              ),
                            ],
                          ),
                          // Render the CURRENT canvas image (cropped after a trim,
                          // else the host base) so a trim updates the display.
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: RawImage(
                              image: _canvasImage,
                              width: _canvasSize.width,
                              height: _canvasSize.height,
                              fit: BoxFit.fill,
                            ),
                          ),
                        )
                      : Image.memory(
                          widget.host.baseImageBytes,
                          fit: BoxFit.fill,
                          gaplessPlayback: true,
                        ),
                ),
                // Layer 2: annotation layer (+ a highlight box on the hovered/selected
                // drawable in the annotate phase). For the editor it is MASKED to the
                // image rect: a drawing can be dragged past the edge (over the
                // checkerboard) but the out-of-bounds part is hidden (and clipped on
                // export). Only this layer is clipped, so the base image keeps its
                // drop shadow. The overlay is unwrapped (structurally identical).
                RepaintBoundary(child: _annotationLayer(inCrop)),
                // Our own text-selection highlight — shown when the inline field is
                // blurred (e.g. while typing a pt value), so the selected range stays
                // visible. When the field is focused it draws its own highlight.
                if (_active &&
                    _editingText &&
                    _textCtl != null &&
                    _textPos != null &&
                    !_textFocus.hasFocus &&
                    !_textCtl!.selection.isCollapsed)
                  IgnorePointer(
                    child: CustomPaint(
                      size: _canvasSize,
                      painter: TextSelectionPainter(
                        span: buildTextSpan(
                          TextDrawable(
                            _textPos!,
                            _textCtl!.text,
                            c.style.value,
                          ),
                        ),
                        origin: _textPos!,
                        selection: _textCtl!.selection,
                      ),
                    ),
                  ),
                // Layer 3: crop scrim — only once a selection drag exists (this
                // display's HUD only shows while the cursor is over it).
                if (_active && inCrop)
                  RepaintBoundary(
                    child: ValueListenableBuilder<Rect?>(
                      valueListenable: _crop.rect,
                      builder: (context, rect, _) {
                        if (rect == null) return const SizedBox.shrink();
                        return Stack(
                          fit: StackFit.expand,
                          children: [
                            CustomPaint(
                              painter: SelectionScrimPainter(selection: rect),
                            ),
                            // Editor: corner handles on a pending selection so it
                            // can be resized/moved before confirming the trim.
                            if (widget.host.cropTrims && !_cropping)
                              CustomPaint(
                                painter: _CropHandlesPainter(rect),
                              ),
                            Positioned(
                              left: rect.left,
                              top: (rect.bottom + 4).clamp(
                                0,
                                _canvasSize.height,
                              ),
                              child: Text(
                                selectionLabel(rect),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  backgroundColor: Color(0xAA000000),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                // Window-snap highlight (Crop tool): the hovered window, or the whole
                // display over bare desktop. The layer is ALWAYS present so the Stack
                // child COUNT is stable (removing a child before the gesture detector
                // when a drag starts would tear down its pan recognizer mid-drag).
                // The rect tweens between targets so the frame glides from one window
                // to the next; the painter is null when nothing should show.
                // One child either way, so the Stack child COUNT stays stable.
                // TweenAnimationBuilder asserts a non-null tween end, so only use it
                // when there's a target; otherwise an empty box.
                snapTarget == null
                    ? const SizedBox.shrink()
                    : TweenAnimationBuilder<Rect?>(
                        tween: RectTween(end: snapTarget),
                        duration: const Duration(milliseconds: 120),
                        curve: Curves.easeOut,
                        builder: (context, rect, _) => IgnorePointer(
                          child: CustomPaint(
                            size: _canvasSize,
                            painter: rect == null
                                ? null
                                : WindowHighlightPainter(rect),
                          ),
                        ),
                      ),
                // Precision HUD: full-screen crosshair + pixel loupe — crop and the
                // raster region tools (blur/pixelate), active display only. OVERLAY
                // only (canvas-space); the editor renders its HUD in the outer
                // stack (screen-space) so it floats over the whole window.
                if (showHud && !_interactive)
                  IgnorePointer(
                    child: CustomPaint(
                      size: _canvasSize,
                      painter: CrosshairPainter(_cursor),
                    ),
                  ),
                // Loupe is bound to the crosshair — shown/hidden together, so it
                // never flickers off when hovering over an existing region.
                if (showHud && !_interactive)
                  Positioned(
                    left: loupeOrigin.dx,
                    top: loupeOrigin.dy,
                    child: IgnorePointer(
                      child: CustomPaint(
                        size: const Size(120, 120),
                        painter: LoupePainter(
                          image: _canvasImage,
                          cursorLogical: _cursor,
                          scaleFactor: widget.host.pixelScale,
                          drawables: _effectiveDrawables(),
                          blurredFull: _blurredFull,
                          pixelatedFull: _pixelatedFull,
                          logicalSize: Size(
                            _canvasSize.width,
                            _canvasSize.height,
                          ),
                        ),
                      ),
                    ),
                  ),
                // Small reticle for the drawing tools (replaces the system arrow
                // with a precise inverting cross). Region tools use the crosshair
                // above. OVERLAY only; the editor renders it in the outer stack.
                if (_showsReticle && !_interactive)
                  IgnorePointer(
                    child: CustomPaint(
                      size: _canvasSize,
                      painter: ReticlePainter(_cursor),
                    ),
                  ),
                // Gesture layer: the overlay keeps it here (full display, box ==
                // logical 1:1). For the editor it is lifted to a sibling scoped to
                // the on-screen image rect (see the return below). The stable key
                // MUST sit on the Stack's DIRECT child so the pan recognizer is
                // matched by key and never torn down mid-drag when a sibling layer
                // (e.g. the snap highlight) toggles — otherwise crop sticks at 0x0.
                if (!_interactive)
                  Positioned.fill(
                    key: const ValueKey('editor-gesture-layer'),
                    child: gestureLayer,
                  ),
                // Inline multiline text editor (Enter commits, Shift+Enter newline).
                if (_active &&
                    _editingText &&
                    _textPos != null &&
                    _textCtl != null)
                  Positioned(
                    left: _textPos!.dx,
                    top: _textPos!.dy,
                    child: Material(
                      type: MaterialType.transparency,
                      child: Focus(
                        onKeyEvent: _onTextKey,
                        child: IntrinsicWidth(
                          child: TextField(
                            controller: _textCtl,
                            focusNode: _textFocus,
                            autofocus: true,
                            maxLines: null,
                            // Don't auto-unfocus when tapping the toolbar: that's how
                            // style controls adjust the text WHILE editing.
                            // Canvas taps still commit explicitly (_onTapUp/_panStart);
                            // switching tools commits via focus loss.
                            onTapOutside: (_) {},
                            cursorColor: c.style.value.color,
                            // Glyphs are TRANSPARENT (the painter draws the visible
                            // text in the real colour) at the real size/family, so the
                            // caret/selection geometry matches the painted result and
                            // commit causes zero shift. Disable strut to match.
                            style: textStyleOf(
                              c.style.value,
                            ).copyWith(color: const Color(0x00000000)),
                            strutStyle: StrutStyle.disabled,
                            decoration: const InputDecoration(
                              isDense: true,
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                // Draggable toolbar — only on the cursor's display (so it "follows"
                // across displays), and hidden while a crop drag is in progress so the
                // selection / screen isn't obscured. Suppressed when the host docks
                // the toolbar itself (e.g. the standalone image editor).
                if (_active && !_cropping && widget.host.showFloatingToolbar)
                  Positioned(
                    left: _toolbarPos.dx,
                    // Bottom-anchored so the tool row (the Column's last/bottom child)
                    // stays put while the options row above it grows upward.
                    bottom: widget.host.size.height - _toolbarPos.dy,
                    // Material ancestor for the toolbar's TextField (pt) + IconButtons.
                    child: Material(
                      type: MaterialType.transparency,
                      child: EditorToolbar(
                        controller: c,
                        onMove: _moveToolbar,
                        onPtEditingDone: () {
                          // Hand keyboard focus back after a toolbar number field
                          // commits: to the inline text field if editing text, else
                          // to the editor so tool shortcuts / Enter-export work again.
                          if (_editingText) {
                            _textFocus.requestFocus();
                          } else {
                            _focus.requestFocus();
                          }
                        },
                        editorBindings: widget.editorBindings,
                      ),
                    ),
                  ),
              ],
            );
            // The overlay (non-interactive) inserts NO Transform — its widget tree
            // stays structurally identical (gesture layer inline in `stack`).
            if (!_interactive) return stack;
            // Editor: the viewport-transformed painters (fitted/scaled; they do not
            // hit-test) UNDER a box-level gesture layer that always covers the
            // window. Drawing maps via _toLogical at any zoom and for images smaller
            // OR larger than the box — an in-transform gesture layer would be clipped
            // by the Transform's hit box (Flutter cannot resize it for overflow).
            final v = _viewport;
            final matrix = Matrix4.identity()
              ..translateByDouble(v.offset.dx, v.offset.dy, 0, 1)
              ..scaleByDouble(v.scale, v.scale, 1, 1);
            return Stack(
              fit: StackFit.expand,
              children: [
                Transform(
                  transform: matrix,
                  transformHitTests: false,
                  child: OverflowBox(
                    minWidth: 0,
                    minHeight: 0,
                    maxWidth: double.infinity,
                    maxHeight: double.infinity,
                    alignment: Alignment.topLeft,
                    child: SizedBox.fromSize(size: _canvasSize, child: stack),
                  ),
                ),
                // Gesture layer scoped EXACTLY to the on-screen image rect, so
                // drawing + the hidden/custom cursor apply only over the image (not
                // the surrounding margins or behind the floating toolbar).
                Positioned(
                  // Stable key on the Stack's direct child so the pan recognizer
                  // survives sibling/viewport rebuilds mid-drag.
                  key: const ValueKey('editor-gesture-layer'),
                  left: v.offset.dx,
                  top: v.offset.dy,
                  width: _canvasSize.width * v.scale,
                  height: _canvasSize.height * v.scale,
                  child: gestureLayer,
                ),
                // Editor HUD in SCREEN space (cursor mapped through the viewport)
                // so the crosshair / reticle / loupe float over the WHOLE window —
                // incl. the checkerboard margin — instead of being clipped to the
                // image like the annotations. Hidden when the cursor leaves the
                // image (showHud / _showsReticle gate on _overCanvas).
                if (showHud)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: CrosshairPainter(v.toLocal(_cursor)),
                      ),
                    ),
                  ),
                if (_showsReticle)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: ReticlePainter(v.toLocal(_cursor)),
                      ),
                    ),
                  ),
                if (showHud) _editorLoupe(v),
                // On-canvas crop confirm/cancel — ABOVE the gesture layer so the
                // ✔/✖ are tappable. Shown only for a pending (drag-released) trim
                // selection (Enter/Esc do the same).
                if (c.tool.value == ToolKind.crop &&
                    !_cropping &&
                    !_cropAdjusting &&
                    _crop.rect.value != null)
                  _cropConfirmButtons(v),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// A small frosted ✔ / ✖ bar shown beside a pending crop-trim selection in the
/// image editor: ✔ confirms the trim (also Enter), ✖ cancels (also Esc).
class _CropConfirmBar extends StatelessWidget {
  const _CropConfirmBar({required this.onConfirm, required this.onCancel});
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: const Color(0xF21A2236),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0x33FFFFFF)),
          boxShadow: const [
            BoxShadow(color: Color(0x66000000), blurRadius: 12, offset: Offset(0, 4)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _CropBtn(
              icon: Icons.check,
              color: const Color(0xFF34D399),
              tooltip: 'Crop (Enter)',
              onTap: onConfirm,
            ),
            const SizedBox(width: 2),
            _CropBtn(
              icon: Icons.close,
              color: const Color(0xFFF87171),
              tooltip: 'Cancel (Esc)',
              onTap: onCancel,
            ),
          ],
        ),
      ),
    );
  }
}

class _CropBtn extends StatelessWidget {
  const _CropBtn({
    required this.icon,
    required this.color,
    required this.tooltip,
    required this.onTap,
  });
  final IconData icon;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(7),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, color: color, size: 20),
        ),
      ),
    );
  }
}

/// Draws the four corner handles on a pending editor crop selection — the SAME
/// blue-circle + white-ring style as the rectangle / blur / pixelate selection
/// handles ([paintResizeHandles]), so they look identical.
class _CropHandlesPainter extends CustomPainter {
  _CropHandlesPainter(this.rect);
  final Rect rect;

  @override
  void paint(Canvas canvas, Size size) => paintResizeHandles(canvas, rect);

  @override
  bool shouldRepaint(_CropHandlesPainter old) => old.rect != rect;
}
