import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import '../capture/capture_bridge.dart';
import '../capture/captured_display.dart';
import '../capture/element_snap.dart';
import '../l10n/gen/app_localizations.dart';
import '../output/clipboard.dart';
import '../shortcuts/hotkey_binding.dart';
import '../shortcuts/shortcut_actions.dart';
import '../overlay/crop_hud.dart';
import '../overlay/hud_lines.dart';
import '../overlay/selection_controller.dart';
import '../overlay/selection_scrim.dart';
import '../overlay/toolbar.dart';
import '../overlay/window_snap.dart';
import '../theme/glimpr_theme.dart';
import 'color_info.dart';
import 'curve.dart';
import 'draw_style.dart';
import 'drawable.dart';
import 'drawable_painter.dart';
import 'geometry.dart';
import 'editor_controller.dart';
import 'editor_host.dart';
import 'hit_test.dart';
import 'hud_config.dart';
import 'loupe_config.dart';
import 'raster.dart';
import 'spotlight.dart';
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

/// The rect a snap commits to: the live AX [element] when present, else the
/// hovered [window], else none. The single source for both the snap highlight
/// and the confirm so they never disagree.
Rect? resolveSnapRect({ElementSnap? element, SnapWindow? window}) =>
    element?.rect ?? window?.rect;

/// The loupe info display (`?` / `/` cycle; [LoupeInfoMode] lives in
/// loupe_config.dart). A top-level var, not per-State, so it is session-sticky
/// across captures within a process. [_loupeInfoModeUserSet] tracks whether the
/// user has cycled it THIS process: until then it follows the persisted setting
/// ([LoupeConfig.infoMode]) so a relaunch restores the last choice; once cycled
/// it owns the value and persists every change via the host.
LoupeInfoMode _loupeInfoMode = LoupeInfoMode.coords;
bool _loupeInfoModeUserSet = false;

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
  // Pixel-loupe geometry (size + magnification), loaded from settings by the
  // host app; shared so the overlay and the image editor look identical.
  final LoupeConfig loupe;
  // HUD options (crosshair lines on/off, marching-ants animation on/off), loaded
  // from settings by the host app; shared across both surfaces.
  final HudConfig hud;
  // The ⌘⌥7 capture-to-pin session (overlay only): the toolbar shows the pin
  // icon + a mode caption so it cannot be mistaken for a normal capture.
  final bool pinMode;

  /// Live-select (recording) session: crop-select only (tool switching is
  /// ignored), the loupe samples live pixels, the toolbar shows the record
  /// caption.
  final bool recordMode;

  /// One-shot per-recording overrides rendered in the record-mode toolbar.
  final RecordOverrides? recordOverrides;
  // Capture layer stack caption below the toolbar (overlay only; null =
  // hidden); accent marks the transient "top layer was replaced" notice.
  final String? layerCaption;
  final bool layerAccent;

  /// Presentation-only: render the base image + drawables ONLY — no
  /// toolbar/HUD/crosshair/loupe/selection — and never become `_active` (the
  /// cross-display active signal is ignored). Used to render the screenshot
  /// session beneath an active record-select overlay, where input + chrome must
  /// belong to the record-select layer on top. Distinct from the viewport-level
  /// `_interactive` getter (image-editor vs overlay).
  final bool presentationOnly;
  const EditorCore({
    super.key,
    required this.controller,
    required this.editorBindings,
    required this.host,
    this.viewportController,
    this.loupe = const LoupeConfig(),
    this.hud = const HudConfig(),
    this.pinMode = false,
    this.recordMode = false,
    this.recordOverrides,
    this.layerCaption,
    this.layerAccent = false,
    this.presentationOnly = false,
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
  // One-shot exact centering: the seed position uses a width ESTIMATE; the
  // first laid-out frame measures the real bar and snaps it to center ONCE.
  // Later width changes (mode bars, option rows) deliberately do NOT re-center
  // (owner: center at start, never chase length changes).
  final GlobalKey _toolbarKey = GlobalKey();
  bool _toolbarCentered = false;
  // Until the first-layout measurement lands, the bar is laid out INVISIBLY
  // (Opacity 0) so the seed position never paints — no one-frame jump.
  bool _toolbarPlaced = false;
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
  // Per-region blur/pixelate effect images, computed when a region settles
  // (ShareX-style, no whole-frame). Cache keyed by (isBlur, rect) -> (image, the
  // strength it was built for); a strength change keeps the OLD image shown until
  // the new one is ready (no flash / no peek at the original). A region being
  // drawn / moved / resized (rect changes) or with no cache yet shows the
  // placeholder. _effectPending dedups concurrent builds by full strength key.
  final Map<(bool, Rect), (ui.Image, double)> _effectCache = {};
  final Set<(bool, Rect, double)> _effectPending = {};
  int _effectGen = 0; // bumped on clear to discard in-flight (stale-frame) builds

  // Move/resize an existing drawable.
  int? _editIndex;
  Drawable? _editOriginal;
  Drawable? _editPreview;
  Offset? _moveStart;
  int? _resizeHandle; // 0-3 corners (TL/TR/BR/BL), 4-7 edge mids (T/R/B/L)
  int? _endpoint; // 0=start 1=end on a Segmented shape (line/arrow/highlighter)
  bool _magnifyMoveDest = false; // moving a magnify: inset (true) vs source body
  Offset? _dragPos; // last drag position, to re-apply a mid-drag Shift toggle

  bool _cropping = false;
  // Editor crop-trim: adjusting a PENDING (drag-released) selection before
  // confirm — resize from a corner or move the whole rect.
  int? _cropHandle; // resize handle index (0-3 corners, 4-7 edge mids)
  Offset? _cropMoveStart; // logical press point when moving the whole selection
  Rect? _cropMoveOrigin; // the pending rect at move-start
  bool get _cropAdjusting => _cropHandle != null || _cropMoveStart != null;

  // Snappable windows for THIS display (capture-time snapshot) + the one the
  // cursor is currently over (crop tool, not mid-drag) — highlighted + snapped.
  List<SnapWindow> _windows = const [];
  Rect? _hoverWindow;
  bool _cancelGesture = false; // right-click cancelled the active drag

  // Precise AX element snap (Advanced experiment) — overlay only, when
  // host.elementSnapAt != null. The live AX candidate under the cursor, the
  // tree-walk depth (wheel up/down), and the async-query throttle/in-flight
  // guard. Window snap stays untouched when the host hook is null.
  ElementSnap? _hoverElement;
  int _elementWalk = 0;
  bool _elementQueryInFlight = false;
  DateTime _lastElementQueryAt = DateTime.fromMillisecondsSinceEpoch(0);
  Offset _lastQueryPos = const Offset(-1e9, -1e9); // last AX-queried point
  // Wheel tree-walk debounce: one physical scroll fires many PointerScrollEvents
  // (trackpad / high-res wheel momentum), so step at most one level per cooldown.
  DateTime _lastWalkStepAt = DateTime.fromMillisecondsSinceEpoch(0);
  // Trackpad two-finger scroll is a pan gesture (not a wheel signal): accumulate
  // its vertical pan and step the element-snap walk once per _kPanWalkStep of
  // travel (resets each gesture in _onPanZoomStart).
  double _panWalkAccum = 0.0;
  static const _kPanWalkStep = 28.0; // logical px of two-finger travel per level
  bool get _elementSnapOn => widget.host.elementSnapAt != null;

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

  /// True when [p] is the OS echoing a half-pixel NUDGED position quantized
  /// to the integer grid: macOS delivers integer logical pointer positions,
  /// so the move event a press generates floors a nudged x.5 back to x.0 —
  /// accepting it would silently undo the nudge by one native pixel in a
  /// seemingly random direction (verified: the echo lands in the same
  /// millisecond as the press). A REAL move lands on a different integer and
  /// passes through.
  bool _isQuantizedEcho(Offset p) =>
      p != _cursor &&
      p == Offset(_cursor.dx.floorToDouble(), _cursor.dy.floorToDouble());

  /// An event-stream position, with the quantized nudge echo redirected to
  /// the aimed cursor — so the press/drag/tap anchor lands exactly where the
  /// loupe says, and the aim never shifts on click.
  Offset _eventPosition(Offset local) {
    final p = _toLogical(local);
    return _isQuantizedEcho(p) ? _cursor : p;
  }

  /// Every _cursor write funnels through here, tagged with its source. The
  /// tag is currently unused — it exists because hunting the loupe's
  /// press-shift required logging exactly this (aimed-cell change + writer);
  /// a future aim regression re-adds one log line here instead of fifteen.
  void _setCursor(Offset p, String src) {
    _cursor = p;
  }

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
    // Drop pre-trim-frame region rasters BEFORE the document changes; commitTrim
    // fires the reconcile listener, which rebuilds them from the trimmed image.
    _clearEffectCache();
    c.commitTrim(shifted, cropped, rect.size);
    c.selectedIndex.value = null;
    setState(() {
      _crop.clear();
      _cropping = false;
    });
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
    // Precise element snap (overlay): the wheel walks the AX tree up (grow) /
    // down (shrink) around the current hover, then re-queries immediately.
    // Handled before the interactive (editor viewport) zoom/pan path.
    if (_elementSnapOn &&
        e is PointerScrollEvent &&
        _active &&
        !_dragging &&
        _snapTools.contains(c.tool.value) &&
        _hoverElement != null) {
      final dy = e.scrollDelta.dy;
      // Ignore jitter / horizontal-only events, and step at most one level per
      // cooldown so a single flick's event burst + momentum tail = one step.
      if (dy.abs() < 2) return;
      final now = DateTime.now();
      if (now.difference(_lastWalkStepAt) < const Duration(milliseconds: 150)) {
        return;
      }
      _lastWalkStepAt = now;
      // Up = grow (walk toward ancestors), down = shrink (re-descend toward the
      // cursor, below the auto-chosen "sensible" element down to the raw leaf).
      _elementWalk = (_elementWalk + (dy < 0 ? 1 : -1)).clamp(-8, 12);
      _maybeQueryElement(_cursor, force: true);
      return;
    }
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
    _panWalkAccum = 0.0;
  }

  /// Trackpad pinch = cursor-anchored zoom; two-finger drag during pinch = pan.
  void _onPanZoomUpdate(PointerPanZoomUpdateEvent e) {
    // Precise element snap (overlay): a two-finger trackpad scroll arrives as a
    // pan gesture, not a wheel signal, so the _onPointerSignal walk never sees
    // it. Translate the vertical pan into the same one-level-per-step walk the
    // mouse wheel does. Handled before the interactive (editor zoom) path.
    if (_elementSnapOn &&
        _active &&
        !_dragging &&
        _snapTools.contains(c.tool.value) &&
        _hoverElement != null) {
      _panWalkAccum += e.panDelta.dy;
      if (_panWalkAccum.abs() >= _kPanWalkStep) {
        final now = DateTime.now();
        if (now.difference(_lastWalkStepAt) >=
            const Duration(milliseconds: 150)) {
          _lastWalkStepAt = now;
          // Fingers up (negative pan) = grow, matching the wheel's scroll-up.
          // If the direction feels inverted on-device, flip this sign.
          _elementWalk = (_elementWalk + (_panWalkAccum < 0 ? 1 : -1))
              .clamp(-8, 12);
          _maybeQueryElement(_cursor, force: true);
        }
        _panWalkAccum = 0.0;
      }
      return;
    }
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
    ToolKind.spotlight,
  };

  /// A drag / edit gesture is in progress (suppresses the window-snap highlight).
  bool get _dragging => _cropping || _dragStart != null || _editIndex != null;

  /// Region-selection tools that get the precision crosshair + pixel loupe (crop
  /// plus the raster regions, where exact alignment on what you obscure matters).
  /// The dimming scrim stays crop-only.
  bool get _showsCrosshair {
    final t = c.tool.value;
    return t == ToolKind.crop ||
        t == ToolKind.blur ||
        t == ToolKind.pixelate ||
        t == ToolKind.spotlight;
  }

  /// Eyedropper (colour sampler) mode is on for THIS (active) canvas.
  bool get _eyedropper => _active && c.eyedropperActive.value;

  /// Sample the base image's pixel under [logical] and set it as the tool colour
  /// (keeping the tool's current alpha so e.g. the highlighter stays translucent),
  /// then leave eyedropper mode. Reads ONE pixel via a 1x1 render — no full-image
  /// byte copy, so it stays light even for a 5K capture.
  // Raw pixels of the CURRENT canvas image, cached while the eyedropper is
  // active so the loupe's live color readout (and the click sample) is an
  // O(1) array lookup instead of a per-move GPU readback. ~4 bytes/px held
  // only for the eyedropper session; dropped on deactivate.
  ui.Image? _pixelCacheImage; // identity guard against image swaps (trim)
  ByteData? _pixelCache;
  bool _pixelCacheBuilding = false;
  // Copy-shortcut feedback: which format line flashes in the readout.
  String? _copiedFormat;
  Timer? _copiedFlash;

  void _onEyedropperFlip() {
    if (_eyedropper) {
      _ensurePixelCache();
    } else {
      _pixelCacheImage = null;
      _pixelCache = null;
      _copiedFlash?.cancel();
      _copiedFormat = null;
    }
  }

  Future<void> _ensurePixelCache() async {
    final img = _canvasImage;
    if (_pixelCacheBuilding ||
        (identical(_pixelCacheImage, img) && _pixelCache != null)) {
      return;
    }
    _pixelCacheBuilding = true;
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    _pixelCacheBuilding = false;
    if (!mounted || !_eyedropper || !identical(img, _canvasImage)) return;
    setState(() {
      _pixelCacheImage = img;
      _pixelCache = data;
    });
  }

  /// The AIMED pixel's color from the cache, or null while it builds (or the
  /// canvas image was swapped — then a rebuild is scheduled). Base pixels
  /// only, matching what a click samples.
  Color? _pixelColorAt(Offset logical) {
    final img = _pixelCacheImage;
    final data = _pixelCache;
    if (img == null || data == null || !identical(img, _canvasImage)) {
      if (_eyedropper) scheduleMicrotask(_ensurePixelCache);
      return null;
    }
    final px = _toPxAimed(logical.dx).clamp(0, img.width - 1);
    final py = _toPxAimed(logical.dy).clamp(0, img.height - 1);
    final b = data.buffer.asUint8List(); // rawRgba: R, G, B, A
    final i = (py * img.width + px) * 4;
    return Color.fromARGB(255, b[i], b[i + 1], b[i + 2]);
  }

  Future<void> _sampleColorAt(Offset logical) async {
    var sampled = _pixelColorAt(logical);
    if (sampled == null) {
      // Cache still building: 1x1 render of the CURRENT canvas image (the
      // displayed pixels — after a trim the host base would be offset).
      final img = _canvasImage;
      final px = _toPxAimed(logical.dx).clamp(0, img.width - 1);
      final py = _toPxAimed(logical.dy).clamp(0, img.height - 1);
      final recorder = ui.PictureRecorder();
      ui.Canvas(
        recorder,
      ).drawImage(img, Offset(-px.toDouble(), -py.toDouble()), ui.Paint());
      final pic = recorder.endRecording();
      final one = await pic.toImage(1, 1);
      pic.dispose();
      final data = await one.toByteData(format: ui.ImageByteFormat.rawRgba);
      one.dispose();
      if (data != null) {
        final b = data.buffer.asUint8List(); // rawRgba: R, G, B, A
        sampled = Color.fromARGB(255, b[0], b[1], b[2]);
      }
    }
    if (sampled != null) {
      final keepAlpha = c.style.value.color.a; // preserve the tool's alpha (0..1)
      c.setColor(sampled.withValues(alpha: keepAlpha));
    }
    c.stopEyedropper();
  }

  // Marching-ants phase (0..1) for the precise-aim HUD lines (crosshair, crop
  // selection border, window-snap highlight). Driven by a ~30fps [Timer] only
  // while one of those is visible (see [_syncMarch]) — not a 60fps vsync ticker —
  // so it stays cheap and doesn't spin frames when a drawing tool is active. The
  // painters listen via CustomPainter(repaint:), so only they repaint each tick.
  final ValueNotifier<double> _march = ValueNotifier<double>(0);
  Timer? _marchTimer;

  @override
  void initState() {
    super.initState();
    _restoreLoupeInfoMode();
    // Seed the crosshair at the real cursor (native passes its display-local
    // position on the cursor display), not the display centre.
    final seed = widget.host.cursorSeed;
    _cursor =
        seed ?? Offset(widget.host.size.width / 2, widget.host.size.height / 2);
    // Center the bar: 160 approximates HALF the full tool row's width; the
    // record-mode bar holds a single tool, so its half-width is far smaller.
    _toolbarPos = Offset(
      widget.host.size.width / 2 - (widget.recordMode ? 40 : 160),
      widget.host.size.height - 60, // dy = toolbar BOTTOM; options grow upward
    );
    // Presentation-only editors never become active (no chrome / no input).
    _active = !widget.presentationOnly && widget.host.startsActive;
    // Live-select: keep the loupe's pixels live under a stationary cursor.
    if (widget.host.liveSelect) _startLiveLoupeTimer();
    _overCanvas = _active; // pointer starts over canvas iff active
    _windows = widget.host.snapWindows;
    c.document.addListener(_rebuild);
    c.document.addListener(_reconcileEffectCache);
    c.selectedIndex.addListener(_rebuild);
    c.selectedIndex.addListener(_unpinIfCleared);
    c.tool.addListener(_rebuild);
    c.tool.addListener(_onToolChanged);
    c.eyedropperToolSwitchCancels = widget.loupe.toolKeysCancelSampling;
    c.eyedropperActive.addListener(_rebuild);
    c.eyedropperActive.addListener(_onEyedropperFlip);
    c.showCursor.addListener(_rebuild);
    c.refocus.addListener(_onRefocusRequested);
    c.stampPick.addListener(_onStampPick);
    c.tool.addListener(_onToolMaybeStamp);
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
    c.phase.addListener(_rebuild);
    c.phase.addListener(_syncCropScrim); // surface region-scrim state to the host
    _crop.rect.addListener(_syncCropScrim);
    c.style.addListener(_onStyleChanged);
    _textFocus.addListener(_rebuild); // repaint our selection on focus changes
    widget.host.activeSignal.addListener(
      _onActiveSignal,
    ); // cursor poll drives active
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _copiedFlash?.cancel();
    c.document.removeListener(_rebuild);
    c.selectedIndex.removeListener(_rebuild);
    c.selectedIndex.removeListener(_unpinIfCleared);
    c.tool.removeListener(_rebuild);
    c.tool.removeListener(_onToolChanged);
    c.eyedropperActive.removeListener(_rebuild);
    c.eyedropperActive.removeListener(_onEyedropperFlip);
    c.showCursor.removeListener(_rebuild);
    c.refocus.removeListener(_onRefocusRequested);
    c.stampPick.removeListener(_onStampPick);
    c.tool.removeListener(_onToolMaybeStamp);
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    c.phase.removeListener(_rebuild);
    c.phase.removeListener(_syncCropScrim);
    _crop.rect.removeListener(_syncCropScrim);
    c.style.removeListener(_onStyleChanged);
    _textFocus.removeListener(_rebuild);
    widget.host.activeSignal.removeListener(_onActiveSignal);
    // Release the per-region blur/pixelate effect images + stop reconciling.
    c.document.removeListener(_reconcileEffectCache);
    _clearEffectCache();
    _textCtl?.dispose();
    _focus.dispose();
    _crop.dispose();
    _textFocus.dispose();
    _marchTimer?.cancel();
    _march.dispose();
    _liveLoupeTimer?.cancel();
    _liveLoupeImg?.dispose();
    super.dispose();
  }

  /// Runs the marching-ants animation only while a dashed HUD line is on screen
  /// (the crosshair, or a window-snap highlight); idle otherwise so we don't
  /// schedule timers/frames for nothing. Safe to call every build (idempotent).
  void _syncMarch(bool active) {
    if (active) {
      _marchTimer ??= Timer.periodic(kHudMarchTick, (_) {
        final step =
            kHudMarchTick.inMilliseconds / kHudMarchDuration.inMilliseconds;
        _march.value = (_march.value + step) % 1.0;
      });
    } else {
      _marchTimer?.cancel();
      _marchTimer = null;
    }
  }

  /// Re-acquire keyboard focus when the controller asks for it (after a modal
  /// dialog closes, or the window regains key). Tool shortcuts run through
  /// [_focus], which a popped route / window-key change doesn't reliably restore.
  /// Post-frame so it lands after the route pop / rebuild settles.
  void _onRefocusRequested() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
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
    // Switching tools commits any in-progress text (its tool is gone).
    if (_editingText) _commitText();
    // Fresh tool intent -> reset the element-snap tree-walk depth (it persists
    // across commits WITHIN a tool so repeated same-level snaps don't re-scroll).
    _elementWalk = 0;
  }

  // ---- region-local blur/pixelate effect cache ---------------------------
  // Effects are rasterised per region when it settles (ShareX-style), keyed by
  // (isBlur, rect, strength). A region being drawn/moved/resized or pending shows
  // the placeholder. No whole-frame pre-compute.

  (bool, Rect)? _effectCacheKey(Drawable d) {
    if (d is BlurDrawable) return (true, d.rect);
    if (d is PixelateDrawable) return (false, d.rect);
    return null;
  }

  /// The effect-image lookup handed to the painters: the cached region image for a
  /// blur/pixelate region (whatever strength it was last built at — so a strength
  /// change shows the previous image until the new one lands), or null (->
  /// placeholder) while it is being drawn/moved/resized or has no cache yet.
  ui.Image? _lookupEffect(Drawable d) {
    final ck = _effectCacheKey(d);
    return ck == null ? null : _effectCache[ck]?.$1;
  }

  /// Ensure each settled blur/pixelate region has a cached effect image at its
  /// CURRENT strength; build misses + strength changes async (keeping the old
  /// image shown meanwhile); evict images for regions that are gone. The region
  /// under active edit ([_editIndex]) is skipped (it shows the placeholder).
  void _reconcileEffectCache() {
    final needed = <(bool, Rect)>{};
    final drawables = c.document.value.drawables;
    for (var i = 0; i < drawables.length; i++) {
      if (i == _editIndex) continue;
      final ck = _effectCacheKey(drawables[i]);
      if (ck == null) continue;
      needed.add(ck);
      final strength = drawables[i].style.strength;
      final cur = _effectCache[ck];
      final buildKey = (ck.$1, ck.$2, strength);
      // Build when nothing is cached for this region OR the cached image is for a
      // different strength (keep the old one visible until the new one is ready).
      if ((cur == null || cur.$2 != strength) &&
          !_effectPending.contains(buildKey)) {
        _buildEffect(buildKey);
      }
    }
    // Spotlight layer: ONE full-canvas effect image when any spotlight wants a
    // background blur/pixelate. Keyed like a region at the full canvas rect.
    // Moving/resizing a hole does NOT invalidate it (it samples the base
    // image); only an effect-kind or strength change rebuilds.
    final layer = spotlightLayerStyle(drawables);
    if (layer != null && layer.spotlightEffect != SpotlightEffect.none) {
      final fullRect = Offset.zero & _canvasSize;
      final isBlur = layer.spotlightEffect == SpotlightEffect.blur;
      final ck = (isBlur, fullRect);
      needed.add(ck);
      final cur = _effectCache[ck];
      final buildKey = (isBlur, fullRect, layer.strength);
      if ((cur == null || cur.$2 != layer.strength) &&
          !_effectPending.contains(buildKey)) {
        _buildEffect(buildKey);
      }
    }
    for (final k
        in _effectCache.keys.where((k) => !needed.contains(k)).toList()) {
      _effectCache.remove(k)?.$1.dispose();
    }
  }

  /// The cached full-canvas effect image for the spotlight layer, or null (the
  /// layer then renders dim-only while the image computes / when effect = none).
  ui.Image? _spotlightLayerImage() {
    final layer = spotlightLayerStyle(_effectiveDrawables());
    if (layer == null || layer.spotlightEffect == SpotlightEffect.none) {
      return null;
    }
    final isBlur = layer.spotlightEffect == SpotlightEffect.blur;
    return _effectCache[(isBlur, Offset.zero & _canvasSize)]?.$1;
  }

  Future<void> _buildEffect((bool, Rect, double) buildKey) async {
    final gen = _effectGen;
    _effectPending.add(buildKey);
    final (isBlur, rect, strength) = buildKey;
    final scale = widget.host.pixelScale;
    final native = Rect.fromLTRB(
      rect.left * scale,
      rect.top * scale,
      rect.right * scale,
      rect.bottom * scale,
    );
    try {
      final img = isBlur
          ? await blurRegion(
              _canvasImage, native, blurSigmaNative(strength, scale))
          : await pixelateRegion(
              _canvasImage, native, pixelateCellNative(strength));
      if (!mounted || gen != _effectGen) {
        img.dispose(); // unmounted, or the cache was cleared mid-build
        return;
      }
      final ck = (isBlur, rect);
      _effectCache[ck]?.$1.dispose(); // replace the old image now the new is ready
      _effectCache[ck] = (img, strength);
      setState(() {});
    } finally {
      _effectPending.remove(buildKey);
    }
  }

  void _clearEffectCache() {
    _effectGen++;
    for (final e in _effectCache.values) {
      e.$1.dispose();
    }
    _effectCache.clear();
    _effectPending.clear();
  }

  @override
  void didUpdateWidget(EditorCore old) {
    super.didUpdateWidget(old);
    // Settings hot-reload (e.g. a ⌘, detour) may change the eyedropper mode.
    c.eyedropperToolSwitchCancels = widget.loupe.toolKeysCancelSampling;
    // The loupe geometry/config loads async (default config at first mount, real
    // values land via a later setState -> didUpdateWidget); re-apply the persisted
    // info mode until the user takes over with `?`/`/`.
    _restoreLoupeInfoMode();
    // New frozen frame (in-place re-capture) -> the pre-computed images are
    // stale; drop them and recompute for the active tool.
    if (old.host.baseImage != widget.host.baseImage) {
      _clearEffectCache(); // pre-rasters were from the old frame
      _reconcileEffectCache(); // rebuild existing regions from the new frame
      _windows = widget.host.snapWindows;
      _hoverWindow = null;
      _hoverElement = null;
      _elementWalk = 0;
      // Re-fit a re-loaded image (interactive editor). Usually moot because the
      // app re-keys EditorCore by ValueKey(image) so a fresh State runs initial
      // fit anyway, but kept correct for in-place baseImage swaps.
      _didInitialFit = false;
    }
  }

  // ---- cross-display follow (driven by the native cursor poll) -----------

  /// The native poll picked the active display for ALL engines. Become active
  /// when it is us (show the HUD/toolbar, seed the crosshair at the pushed point,
  /// take Flutter keyboard focus); step down when it is another display (hide the
  /// HUD, drop transient draw state). One authoritative signal — no per-engine
  /// guessing or async handoff, so no flicker.
  void _onActiveSignal() {
    if (widget.presentationOnly) return; // never activates; stays chrome-less
    final sig = widget.host.activeSignal.value;
    final mine = sig.id == widget.host.hostId;
    if (mine && !_active) {
      setState(() {
        _active = true;
        _setCursor(sig.cursor, 'signal'); // land where the cursor crossed in
      });
      _focus.requestFocus();
    } else if (!mine && _active) {
      setState(() {
        _active = false;
        _resetDrawState();
        _resetEditState();
      });
    }
    _syncCropScrim();
  }

  /// Keep [c.cropScrimActive] in sync with whether this core is currently
  /// painting its region scrim (active + in crop + a selection exists). The
  /// multi-display overlay broadcasts it so the OTHER displays dim fully during
  /// a region drag; a presentation-only / inactive core resolves to false.
  void _syncCropScrim() {
    c.cropScrimActive.value = _active && _inCrop && _crop.rect.value != null;
  }

  bool _pasting = false; // re-entrancy guard for paste (tool-switch + ⌘V)

  /// Paste a clipboard image as a movable/resizable [ImageDrawable]. No-op when
  /// the clipboard holds no decodable image.
  Future<void> _pasteImage() async {
    if (_pasting) return;
    _pasting = true;
    try {
      final bytes = await clipboardReadImage();
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
      // Pin it so its handles show immediately (handles == pinned selection).
      _selectAndPin(c.document.value.drawables.length - 1);
    } finally {
      _pasting = false;
    }
  }

  /// Choose a file image as the stamp tool's current "stamp" (reusable for
  /// repeated placement). No-op when the user cancels or the file is undecodable.
  Future<void> _pickStamp() async {
    const group = XTypeGroup(
      label: 'Images',
      extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'tiff', 'heic'],
    );
    final file = await openFile(acceptedTypeGroups: [group]);
    if (file == null || !mounted) return;
    final bytes = await file.readAsBytes();
    ui.Image img;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      img = (await codec.getNextFrame()).image;
    } catch (_) {
      return; // not a decodable image
    }
    if (!mounted) return;
    // Keep the bytes so the overlay can broadcast this stamp to the other
    // displays (which each decode their own ui.Image).
    c.setStamp(img, bytes);
  }

  /// Default placement rect for a stamp: native size / scale, fit within ~half
  /// the display (never upscale), centered on the tap point [p].
  Rect _stampRectAt(Offset p, ui.Image img) {
    final sf = widget.host.pixelScale;
    final w = img.width / sf, h = img.height / sf;
    final fit = [
      1.0,
      widget.host.size.width * 0.5 / w,
      widget.host.size.height * 0.5 / h,
    ].reduce((a, b) => a < b ? a : b);
    return Rect.fromCenter(center: p, width: w * fit, height: h * fit);
  }

  void _onStampPick() => _pickStamp();

  // Selecting the stamp tool with no image loaded opens the picker immediately
  // (so the user does not have to hunt for the option-bar button on first use).
  // Gated on [_active] like the eyedropper: the tool change is BROADCAST to every
  // display (overlay cross-display sync), so without this guard each display would
  // open its own file dialog. Only the display the user is on (active) opens one.
  void _onToolMaybeStamp() {
    if (_active && c.tool.value == ToolKind.stamp && c.stampImage.value == null) {
      _pickStamp();
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
      case ToolKind.stamp:
        // The stamp tool targets pasted/placed images (so its placed image is
        // selectable / resizable while the tool stays active for more stamps).
        return (d) => d is ImageDrawable;
      case ToolKind.magnify:
        return (d) => d is MagnifyDrawable;
      case ToolKind.spotlight:
        return (d) => d is SpotlightDrawable;
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
    ToolKind.stamp,
    ToolKind.magnify,
    ToolKind.spotlight,
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
      // Eyedropper active -> just leave sampling mode (don't exit capture).
      if (_eyedropper) {
        c.stopEyedropper();
        return KeyEventResult.handled;
      }
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
    // Element snap: ',' shrinks / '.' grows the AX selection along the tree — a
    // keyboard fallback for the wheel (a trackpad two-finger scroll is a drag,
    // not a wheel, so it can't walk). Bare keys only, so ⌘',' still opens
    // Settings below. Mirrors the wheel: '.'/'>' grow (+1), ','/'<' shrink (-1).
    if (_elementSnapOn &&
        pressed.isEmpty &&
        !_dragging &&
        _snapTools.contains(c.tool.value) &&
        (key == LogicalKeyboardKey.comma || key == LogicalKeyboardKey.period)) {
      // Always CONSUME the key in this mode (no system error beep), even with no
      // element yet under the cursor — the forced query establishes one.
      final grow = key == LogicalKeyboardKey.period;
      _elementWalk = (_elementWalk + (grow ? 1 : -1)).clamp(-8, 12);
      _maybeQueryElement(_cursor, force: true);
      return KeyEventResult.handled;
    }
    // ? or / cycles the loupe info display: coordinates -> element level ->
    // shortcuts -> all hidden. A FIXED (non-rebindable) shortcut; shown in
    // Settings > Shortcuts as reserved. Match BOTH logical keys: bare `/` is
    // `slash`, but Shift+`/` (= `?`) reports `question`, not slash+Shift — so
    // checking slash alone misses `?` (and the unhandled key beeps).
    if ((key == LogicalKeyboardKey.slash ||
            key == LogicalKeyboardKey.question) &&
        pressed.difference({HotkeyModifier.shift}).isEmpty) {
      setState(() {
        _loupeInfoMode = LoupeInfoMode
            .values[(_loupeInfoMode.index + 1) % LoupeInfoMode.values.length];
        _loupeInfoModeUserSet = true;
      });
      // Persist so the choice survives relaunch (the host writes to Settings).
      widget.host.persistLoupeInfoMode(_loupeInfoMode);
      return KeyEventResult.handled;
    }
    // ⌘, opens Settings (fixed macOS Preferences convention; reserved). The host
    // decides whether to dismiss first (the overlay does, the editor doesn't).
    if (isOpenSettingsChord(e, pressed)) {
      widget.host.openSettings();
      return KeyEventResult.handled;
    }
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
    if (action == kEditorCopyHexKey ||
        action == kEditorCopyRgbKey ||
        action == kEditorCopyHslKey) {
      // Copy the loupe's aimed color — only meaningful while sampling.
      if (!_eyedropper) return KeyEventResult.ignored;
      final col = _pixelColorAt(_cursor);
      if (col != null) {
        final fmt = action == kEditorCopyHexKey
            ? 'HEX'
            : action == kEditorCopyRgbKey
                ? 'RGB'
                : 'HSL';
        Clipboard.setData(ClipboardData(
          text: fmt == 'HEX'
              ? hexOf(col)
              : fmt == 'RGB'
                  ? rgbCssOf(col)
                  : hslCssOf(col),
        ));
        // Feedback where the eyes already are: the copied line in the loupe
        // readout flashes accent + a check for a moment.
        _copiedFlash?.cancel();
        setState(() => _copiedFormat = fmt);
        _copiedFlash = Timer(const Duration(milliseconds: 1200), () {
          if (mounted) setState(() => _copiedFormat = null);
        });
      }
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
    if ((action == kEditorConfirmKey || numpadConfirm) && _eyedropper) {
      _sampleColorAt(_cursor); // Enter samples (handy after an arrow-nudge)
      return KeyEventResult.handled;
    }
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
        // the snap target — the AX element (element mode) or the window under the
        // cursor, or the whole display when none is under it.
        final s = _snapCommit(_cursor);
        widget.host.onExport(s.rect, s.window);
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
    if (action == kEditorDuplicateKey && c.selectedIndex.value != null) {
      c.duplicateSelected();
      return KeyEventResult.handled;
    }
    if (action == kEditorBringToFrontKey && c.selectedIndex.value != null) {
      c.bringSelectedToFront();
      return KeyEventResult.handled;
    }
    if (action == kEditorSendToBackKey && c.selectedIndex.value != null) {
      c.sendSelectedToBack();
      return KeyEventResult.handled;
    }
    if (action != null && kEditorToolActionKey.containsValue(action)) {
      final tool = kEditorToolActionKey.entries
          .firstWhere((x) => x.value == action)
          .key;
      // Live-select (recording): the session is crop-select only — annotation
      // tools would silently discard work (nothing is exported).
      if (widget.recordMode && tool != ToolKind.crop) {
        return KeyEventResult.handled;
      }
      c.selectTool(tool);
      return KeyEventResult.handled;
    }

    // Arrow-nudge for the region tools (crop + blur/pixelate) AND the eyedropper:
    // move the crosshair by ONE PHYSICAL pixel (= 1 / scaleFactor logical points —
    // a single pixel on Retina, not 2-3) and warp the OS cursor to match so a
    // later physical move continues from the nudged point. Also nudges the
    // in-progress region's dragging corner.
    if (_showsCrosshair || _eyedropper) {
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
          _setCursor(next, 'nudge');
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

  // Resize handles for a box: 4 corners (0-3: TL, TR, BR, BL) then 4 edge
  // midpoints (4: top, 5: right, 6: bottom, 7: left). Corners scale both axes;
  // edge mids scale a single axis. Index order is shared by the hit-test and
  // [_resizeRect].
  List<Offset> _rectHandles(Rect r) => [
    r.topLeft,
    r.topRight,
    r.bottomRight,
    r.bottomLeft,
    Offset(r.center.dx, r.top),
    Offset(r.right, r.center.dy),
    Offset(r.center.dx, r.bottom),
    Offset(r.left, r.center.dy),
  ];

  static const _handleMovesLeft = {0, 3, 7};
  static const _handleMovesRight = {1, 2, 5};
  static const _handleMovesTop = {0, 1, 4};
  static const _handleMovesBottom = {2, 3, 6};

  /// New rect from dragging handle [h] (0-3 corners, 4-7 edge mids) to [p].
  /// Corners move two edges; edge mids move a single axis. Normalised so it never
  /// inverts when dragged past the opposite edge.
  Rect _resizeRect(Rect r, int h, Offset p) {
    var l = r.left, t = r.top, rt = r.right, b = r.bottom;
    if (_handleMovesLeft.contains(h)) l = p.dx;
    if (_handleMovesRight.contains(h)) rt = p.dx;
    if (_handleMovesTop.contains(h)) t = p.dy;
    if (_handleMovesBottom.contains(h)) b = p.dy;
    return Rect.fromLTRB(
      math.min(l, rt),
      math.min(t, b),
      math.max(l, rt),
      math.max(t, b),
    );
  }

  bool _nearHandles(Drawable d, Offset p) {
    if (d is RectShaped) {
      // Handles are flush with the shape's bounds (matching the drawn handles).
      for (final h in _rectHandles((d as RectShaped).rect)) {
        if ((h - p).distance <= 16) return true;
      }
    }
    return d.bounds.inflate(8).contains(p);
  }

  /// True when the cursor is over an annotation the active (typed) tool would
  /// engage — its current selection's handle zone, or a same-type drawable under
  /// the cursor. Used to suppress the window-snap highlight: if you're clearly
  /// aiming at an annotation, the snap frame is redundant noise. Type-less tools
  /// (crop) never match — they don't target annotations, so snapping still wins.
  bool _overAnnotation(Offset p) {
    if (_typeFilter() == null) return false;
    final drawables = c.document.value.drawables;
    final cur = c.selectedIndex.value;
    if (cur != null &&
        cur < drawables.length &&
        _nearHandles(drawables[cur], p)) {
      return true;
    }
    return _hitActiveType(p) != null;
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
    final p = _eventPosition(e.localPosition);
    setState(() => _setCursor(p, 'hover'));
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
    // Hover-PREVIEW (uniform for EVERY tool, including the universal Select tool):
    // hovering a same-type drawable shows its handles so the user can see what is
    // clickable. It is a PREVIEW only and NON-STICKY — it clears the instant the
    // cursor leaves the shape onto empty canvas (idx == null). Nothing stays
    // selected from hovering alone: a freshly drawn shape is not left selected, and
    // the Select tool no longer "sticks" a hovered shape. To LOCK a selection (to
    // reach the option bar to restyle / reset, or to move / resize), the user
    // CLICKS it — _onTapUp pins it (_pinned), and a pinned selection ignores hover
    // until a click on empty space deselects.
    final idx = _hitActiveType(p);
    if (cur != idx) c.selectedIndex.value = idx;
  }

  void _onTapUp(TapUpDetails d) {
    if (_editingText) {
      _commitText();
      return;
    }
    if (_eyedropper) {
      _sampleColorAt(_cursor); // sample where the loupe is (respects arrow-nudge)
      return;
    }
    final p = _eventPosition(d.localPosition);
    // Window-snap (ShareX-style): a tap on a window applies the snap tool to that
    // window's bounds — crop captures it; blur/pixelate/rectangle/ellipse add a
    // drawable spanning it. With NO window under the cursor the tools fall back
    // to their normal tap (crop -> whole display; the rest select).
    final win = topmostWindowAt(_windows, p);
    // The snap rect for the drawable tools: the AX element (element mode) else
    // the window. The crop/confirm path uses _snapCommit (it also needs the
    // SnapWindow for naming + the window-shape mask).
    final snapRect = _snapRectAt(p);
    final style = c.style.value;
    switch (c.tool.value) {
      case ToolKind.crop:
        // Editor: crop is drag-to-trim (then Enter/✔ confirms); a bare tap does
        // nothing. Overlay: a tap captures the snapped element/window / whole
        // display.
        if (widget.host.cropTrims) return;
        final s = _snapCommit(p);
        widget.host.onExport(s.rect, s.window); // null window -> whole display
        return;
      // For the snap tools, selecting an existing same-type region WINS over
      // snapping a new one — so you can click a committed region to re-select /
      // restyle it even when it sits over a window. No hit + a window under the
      // cursor -> snap a new region; nothing at all -> deselect.
      case ToolKind.blur:
        if (_hitActiveType(p) case final hit?) {
          _selectAndPin(hit);
        } else if (snapRect != null) {
          c.commitDrawable(BlurDrawable(snapRect, style));
          _markElementDivergence();
        } else {
          _selectAndPin(null);
        }
        return;
      case ToolKind.pixelate:
        if (_hitActiveType(p) case final hit?) {
          _selectAndPin(hit);
        } else if (snapRect != null) {
          c.commitDrawable(PixelateDrawable(snapRect, style));
          _markElementDivergence();
        } else {
          _selectAndPin(null);
        }
        return;
      case ToolKind.rectangle:
        if (_hitActiveType(p) case final hit?) {
          _selectAndPin(hit);
        } else if (snapRect != null) {
          c.commitDrawable(RectangleDrawable(snapRect, style));
          _markElementDivergence();
        } else {
          _selectAndPin(null);
        }
        return;
      case ToolKind.ellipse:
        if (_hitActiveType(p) case final hit?) {
          _selectAndPin(hit);
        } else if (snapRect != null) {
          c.commitDrawable(EllipseDrawable(snapRect, style));
          _markElementDivergence();
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
            StepDrawable(
              p,
              nextStepNumber(
                c.document.value.drawables,
                start: style.stepStart,
              ),
              style,
            ),
          );
        } else {
          _selectAndPin(idx);
        }
        return;
      case ToolKind.stamp:
        // Tap on empty space places a new stamp at the current image; tap on an
        // existing image selects it (then resize/move). No image loaded yet ->
        // open the picker. The tool STAYS active so you can keep stamping.
        final img = c.stampImage.value;
        if (img == null) {
          c.requestStampPick();
          return;
        }
        final hit = _hitActiveType(p);
        if (hit == null) {
          c.commitDrawable(ImageDrawable(_stampRectAt(p, img), img, style));
          // Pin it so its handles show immediately (handles == pinned selection).
          _selectAndPin(c.document.value.drawables.length - 1);
        } else {
          _selectAndPin(hit);
        }
        return;
      case ToolKind.spotlight:
        if (_hitActiveType(p) case final hit?) {
          _selectAndPin(hit);
        } else if (win != null) {
          c.commitSpotlight(SpotlightDrawable(win.rect, style));
        } else {
          _selectAndPin(null);
        }
        return;
      case ToolKind.arrow:
      case ToolKind.line:
      case ToolKind.pen:
      case ToolKind.highlighter:
      case ToolKind.paste:
      case ToolKind.magnify:
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

  /// The rect the snap tools commit to at [p]: the live AX element (AX mode +
  /// a current hover candidate) else the top-most window, else null.
  Rect? _snapRectAt(Offset p) => resolveSnapRect(
      element: _elementSnapOn ? _hoverElement : null,
      window: topmostWindowAt(_windows, p));

  /// The (selectionRect, SnapWindow) a confirm/export commits at [p]. An AX
  /// element becomes a fixed rect with NO windowId, so the overlay takes the
  /// rectangular-crop path (a sub-element is rectangular); a window snap keeps
  /// its windowId so the export masks to the window's real rounded shape.
  /// Emit the frozen-vs-live geometry divergence perf mark for the current
  /// element hover at a COMMIT (the element's window may have moved/resized
  /// since the freeze). Only actual movement is logged — a stationary window
  /// produces no mark. No-op outside element mode / with no hover element.
  void _markElementDivergence() {
    final el = _hoverElement;
    if (!_elementSnapOn || el == null) return;
    Rect? freeze;
    if (el.windowId != null) {
      for (final w in _windows) {
        if (w.windowId == el.windowId) {
          freeze = w.rect;
          break;
        }
      }
    }
    final d = el.divergence(freeze);
    if (d != null && (d.dx.abs() > 1 || d.dy.abs() > 1 || d.resized)) {
      CaptureBridge.perfMark(
          'elementSnap diverge dx=${d.dx.round()} dy=${d.dy.round()} '
          'resized=${d.resized}');
    }
  }

  ({Rect? rect, SnapWindow? window}) _snapCommit(Offset p) {
    final el = _elementSnapOn ? _hoverElement : null;
    if (el != null) {
      _markElementDivergence();
      return (
        rect: el.rect,
        window: SnapWindow(rect: el.rect, title: el.title, app: el.app),
      );
    }
    final w = topmostWindowAt(_windows, p);
    return (rect: w?.rect, window: w);
  }

  /// Fire a throttled async AX element query at display-local [p] and fold the
  /// result into the snap highlight. Overlay-only (guarded by [_elementSnapOn]).
  /// A hung target app returns null -> the window-snap highlight stands. [force]
  /// bypasses the throttle (a wheel tree-walk).
  void _maybeQueryElement(Offset p, {bool force = false}) {
    if (!_elementSnapOn || _elementQueryInFlight) return;
    // Movement gate: a stationary cursor re-queries the same element, so skip it
    // — this drops idle-hover queries (and the load on the hovered app) without
    // hurting responsiveness. The wheel tree-walk passes force (depth changed,
    // not the cursor) to bypass both this and the time throttle.
    if (!force && (p - _lastQueryPos).distance < 3) return;
    final now = DateTime.now();
    if (!force &&
        now.difference(_lastElementQueryAt) < const Duration(milliseconds: 33)) {
      return;
    }
    _elementQueryInFlight = true;
    _lastElementQueryAt = now;
    _lastQueryPos = p;
    final q = p;
    final requestedWalk = _elementWalk;
    widget.host.elementSnapAt!(q, walk: requestedWalk).then((el) {
      _elementQueryInFlight = false;
      if (!mounted || !_active) return;
      // Drop a stale reply: the cursor moved on, or snapping no longer applies.
      if ((_cursor - q).distance > 24) return;
      if (!_snapTools.contains(c.tool.value) ||
          _dragging ||
          _overAnnotation(q)) {
        return;
      }
      // The user scrolled while this was in flight -> the depth changed; re-fire
      // with the latest depth rather than applying this stale one.
      if (_elementWalk != requestedWalk) {
        _maybeQueryElement(_cursor, force: true);
        return;
      }
      setState(() {
        _hoverElement = el;
        // Clamp the counter to the depth the native walk ACTUALLY reached (it
        // stops at the real root/leaf), so scrolling past the end can't overshoot
        // — otherwise reversing direction has a dead stretch.
        if (el != null) _elementWalk = el.appliedWalk;
        _hoverWindow = resolveSnapRect(
            element: el, window: topmostWindowAt(_windows, _cursor));
      });
      CaptureBridge.perfMark(el == null
          ? 'elementSnap fallback'
          : 'elementSnap lat=${el.latencyUs} walk=$_elementWalk');
    });
  }

  /// Track the crosshair from the raw pointer stream (outermost Listener), so it
  /// follows everywhere on the active display — over the toolbar, and while the
  /// left button is still held after a right-click cancel.
  void _trackCursor(PointerEvent e) {
    if (!_active) return;
    final p = _eventPosition(e.localPosition);
    // Window-snap: highlight the top-most window under the cursor for the snap
    // tools (crop/blur/pixelate/rectangle/ellipse), but not while dragging and not
    // while hovering an annotation the tool would engage (then the snap frame is
    // redundant). The full-screen crosshair / reticle still follow the pointer.
    final wantSnap =
        _snapTools.contains(c.tool.value) && !_dragging && !_overAnnotation(p);
    final hover = wantSnap ? topmostWindowAt(_windows, p) : null;
    setState(() {
      _setCursor(_clampToDisplay(p), 'track');
      if (!wantSnap) {
        _hoverElement = null;
        // Keep _elementWalk: persist the relative tree-walk depth across commits
        // and brief leaves (e.g. blurring several same-level elements) so the
        // user doesn't re-scroll each time. It resets on tool change / new
        // capture session / crop drag.
        _hoverWindow = null;
      } else if (_elementSnapOn &&
          _hoverElement != null &&
          _hoverElement!.rect.contains(p)) {
        // Keep the element highlight while still inside it; an async query
        // refines it as the cursor moves.
        _hoverWindow = _hoverElement!.rect;
      } else {
        // Outside any element candidate -> show the window rect immediately; an
        // AX query may refine it to a sub-element.
        _hoverWindow = hover?.rect;
      }
    });
    if (wantSnap && _elementSnapOn) _maybeQueryElement(p);
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
      !_eyedropper && // eyedropper uses the full crosshair+loupe, not the reticle
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
    // Eyedropper active -> right-click cancels sampling (stays in capture).
    if (_eyedropper) {
      c.stopEyedropper();
      return;
    }
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
    //  3) an annotation is selected -> DESELECT it (a safe step-back), stay;
    //  4) otherwise -> EXIT the capture, like Esc (nothing selected, and nothing
    //     of the active tool's type under the cursor, so the spot is "empty").
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
    // A visible annotation selection -> right-click on empty space DESELECTS it
    // first (a safe step-back), so only a second right-click (nothing selected)
    // exits. Skipped in the crop phase (no annotation selection is shown there).
    if (!_inCrop && c.selectedIndex.value != null) {
      c.selectedIndex.value = null;
      return;
    }
    // Nothing selected and nothing of the active tool's type here -> exit, unless
    // the user disabled right-click-to-exit in settings (Esc still exits).
    if (widget.host.rightClickExits) widget.host.onCancel();
  }

  void _resetDrawState() {
    _preview = null;
    _dragStart = null;
    _strokePoints = null;
    _cropHandle = null;
    _cropMoveStart = null;
    _cropMoveOrigin = null;
  }

  void _resetEditState() {
    _editIndex = null;
    _editOriginal = null;
    _editPreview = null;
    _moveStart = null;
    _resizeHandle = null;
    _endpoint = null;
    _magnifyMoveDest = false;
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
    final p = _eventPosition(d.localPosition);
    // Eyedropper: a drag doesn't draw — just track the cursor (so the loupe
    // follows); _panEnd samples at the release point.
    if (_eyedropper) {
      widget.host.cursor.setDrawingLock(false);
      setState(() => _setCursor(p, 'eyeStart'));
      return;
    }
    // The editor has no outer pointer tracker (the overlay uses _trackCursor on
    // the full-window Listener), so the reticle/crosshair must advance from the
    // pan stream here — otherwise it freezes at the drag's start point.
    if (_interactive) setState(() => _setCursor(p, 'editStart'));
    if (c.tool.value == ToolKind.crop) {
      // Editor: with a pending selection, a press on a corner resizes it and a
      // press inside moves it; elsewhere starts a fresh selection.
      final pending = widget.host.cropTrims ? _crop.rect.value : null;
      if (pending != null) {
        final tol = 16 / _viewport.scale; // ~16 screen px regardless of zoom
        final handles = _rectHandles(pending);
        for (var ci = 0; ci < handles.length; ci++) {
          if ((handles[ci] - p).distance <= tol) {
            _cropHandle = ci;
            setState(() => _setCursor(p, 'handleStart'));
            return;
          }
        }
        if (pending.contains(p)) {
          _cropMoveStart = p;
          _cropMoveOrigin = pending;
          setState(() => _setCursor(p, 'moveStart'));
          return;
        }
      }
      _cropping = true;
      setState(() {
        _setCursor(p, 'cropStart');
        _hoverWindow = null;
        _hoverElement = null;
        _elementWalk = 0;
      });
      _crop.begin(p);
      return;
    }
    final drawables = c.document.value.drawables;
    final filter = _typeFilter();
    // Handle grab is restricted to the CURRENTLY-SELECTED (pinned) shape: only a
    // selected shape shows handles, so only it is handle-draggable. This stops an
    // overlapping higher-z neighbour (which shows no handles) from stealing the
    // press the moment two handle zones overlap. To resize another shape, click
    // it first (which pins it + reveals its handles).
    final selIdx = _pinned ? c.selectedIndex.value : null;
    final sel =
        (selIdx != null &&
            selIdx >= 0 &&
            selIdx < drawables.length &&
            (filter == null || filter(drawables[selIdx])))
        ? drawables[selIdx]
        : null;
    // Rect-shape corner/edge resize (rectangle/ellipse + the raster regions).
    if (sel is RectShaped && _rectShapeTools.contains(c.tool.value)) {
      final handles = _rectHandles((sel as RectShaped).rect);
      for (var ci = 0; ci < handles.length; ci++) {
        if ((handles[ci] - p).distance <= 16) {
          _editIndex = selIdx;
          _editOriginal = drawables[selIdx!];
          _editPreview = drawables[selIdx];
          _resizeHandle = ci;
          return; // already the pinned selection
        }
      }
    }
    // Segment control-point drag (line/arrow/highlighter + the universal Select
    // tool): a press near a control point (endpoints + interior curve points)
    // moves just that point; a press on the body falls through to move.
    // `_endpoint` indexes into `points`.
    if (sel is Segmented &&
        (_segmentTools.contains(c.tool.value) || _isSelectTool)) {
      final pts = (sel as Segmented).points;
      for (var ei = 0; ei < pts.length; ei++) {
        if ((pts[ei] - p).distance <= 16) {
          _editIndex = selIdx;
          _editOriginal = drawables[selIdx!];
          _editPreview = drawables[selIdx];
          _endpoint = ei;
          return;
        }
      }
    }
    final hit = _hitActiveType(p);
    if (hit != null) {
      _editIndex = hit;
      _editOriginal = drawables[hit];
      _editPreview = drawables[hit];
      _moveStart = p;
      _resizeHandle = null;
      // For a magnify, a press inside the inset moves the inset (dest wins on
      // overlap); a press in the source body moves the source.
      final h = drawables[hit];
      _magnifyMoveDest = h is MagnifyDrawable && h.destRect.contains(p);
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
    final logical = _eventPosition(d.localPosition);
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
      if (_showsCrosshair) setState(() => _setCursor(p, 'cancelTrack'));
      return;
    }
    // Editor: advance the reticle/crosshair from the pan stream for EVERY tool
    // (no outer tracker); the crop/blur/pixelate branches below also keep it.
    if (_interactive) setState(() => _setCursor(p, 'editU'));
    if (c.tool.value == ToolKind.crop) {
      // Editor: resize a pending selection from its grabbed corner, or move the
      // whole rect; otherwise extend the in-progress selection. Shift squares the
      // resize / draw (capped to the canvas), like a rectangle drag.
      final shift = HardwareKeyboard.instance.isShiftPressed;
      if (_cropHandle != null) {
        final cur = _crop.rect.value;
        if (cur != null) {
          final h = _cropHandle!;
          // Corners square-constrain (Shift) against the opposite corner; edge
          // mids are single-axis (Shift is a no-op).
          final cp = (shift && h < 4)
              ? _squareCornerIn(_rectHandles(cur)[(h + 2) % 4], p, _canvasSize)
              : p;
          _crop.set(_resizeRect(cur, h, cp));
        }
      } else if (_cropMoveStart != null && _cropMoveOrigin != null) {
        _crop.set(_cropMoveOrigin!.shift(p - _cropMoveStart!));
      } else {
        final a = _crop.anchor;
        final to = (shift && a != null) ? _squareCornerIn(a, p, _canvasSize) : p;
        _crop.update(to);
      }
      setState(() => _setCursor(p, 'cropU'));
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
          _setCursor(p, 'blurU'); // keep the crosshair/loupe on the corner
          _preview = BlurDrawable(Rect.fromPoints(s, cp), c.style.value);
        });
        break;
      case ToolKind.pixelate:
        final cp = shift ? _squareCorner(s, p) : p;
        setState(() {
          _setCursor(p, 'pixU');
          _preview = PixelateDrawable(Rect.fromPoints(s, cp), c.style.value);
        });
        break;
      case ToolKind.magnify:
        // Drag the SOURCE; the inset auto-appears down-right at the default
        // factor (Shift squares the source like a box tool).
        final cp = shift ? _squareCorner(s, p) : p;
        final srcR = Rect.fromPoints(s, cp);
        final f = c.style.value.magnifyFactor;
        final destC = srcR.bottomRight +
            Offset(srcR.width * f / 2 + 16, srcR.height * f / 2 + 16);
        setState(() => _preview = MagnifyDrawable(srcR, destC, c.style.value));
        break;
      case ToolKind.spotlight:
        final cp = shift ? _squareCorner(s, p) : p;
        setState(() {
          _setCursor(p, 'spotU'); // keep the crosshair/loupe on the corner
          _preview = SpotlightDrawable(Rect.fromPoints(s, cp), c.style.value);
        });
        break;
      case ToolKind.text:
      case ToolKind.step:
      case ToolKind.paste:
      case ToolKind.stamp:
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
      final pts = [...seg.points];
      final i = _endpoint!.clamp(0, pts.length - 1);
      // Shift constrains an ENDPOINT drag to 8 directions from the opposite end;
      // interior control points move freely.
      final isEnd = i == 0 || i == pts.length - 1;
      final anchor = i == 0 ? pts.last : pts.first;
      pts[i] = (shift && isEnd) ? _snap8(anchor, p) : p;
      setState(() => _editPreview = seg.withPoints(pts));
    } else if (_resizeHandle != null && orig is RectShaped) {
      final shape = orig as RectShaped;
      final h = _resizeHandle!;
      // Corners constrain on Shift; edge mids are single-axis (Shift no-op).
      // A pasted/stamped IMAGE locks to its NATIVE aspect (treat it as a picture,
      // not a free box); every other shape squares.
      final Offset cp;
      if (shift && h < 4) {
        final anchor = _rectHandles(shape.rect)[(h + 2) % 4];
        if (orig is ImageDrawable) {
          final img = orig.image;
          cp = aspectCorner(anchor, p, img.width / img.height);
        } else {
          cp = _squareCorner(anchor, p);
        }
      } else {
        cp = p;
      }
      setState(
        () => _editPreview = shape.resizedTo(_resizeRect(shape.rect, h, cp)),
      );
    } else {
      final start = _moveStart;
      if (start != null) {
        if (orig is MagnifyDrawable) {
          // Inset move relocates the loupe; source-body move re-aims the capture
          // (dest stays). Source RESIZE is handled by the RectShaped branch above.
          setState(() => _editPreview = _magnifyMoveDest
              ? orig.withDestCenter(orig.destCenter + (p - start))
              : orig.resizedTo(orig.sourceRect.shift(p - start)));
        } else {
          setState(() => _editPreview = orig.moved(p - start));
        }
      }
    }
  }

  void _panEnd(DragEndDetails d) {
    widget.host.cursor.setDrawingLock(
      false,
    ); // drag finished -> release the cursor confine
    if (_eyedropper) {
      _sampleColorAt(_cursor); // a drag in eyedropper samples at the release
      return;
    }
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
      _cropHandle = null;
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
    if (prev == null || prev.bounds.longestSide < 3) return;
    // A freshly drawn line/arrow/highlighter is a straight 2-point shape; seed the
    // configured number of interior control points along it so it can be curved.
    Drawable out = prev;
    if (prev is Segmented) {
      final seg = prev as Segmented;
      final n = prev.style.curvePoints.clamp(kCurvePointsMin, kCurvePointsMax);
      out = seg.withPoints(seedInterior(seg.start, seg.end, n));
    } else if (prev is PenDrawable) {
      // Freehand strokes are decimated ONCE on release: the points are stored
      // already-simplified (lighter to keep / paint / hit-test) and the painter
      // draws them as a smooth Catmull-Rom spline.
      out = PenDrawable(
          decimateByDistance(prev.points, kPenSmoothMinDist), prev.style);
    }
    if (out is SpotlightDrawable) {
      // One commit appends the hole AND equalises the layer-wide fields of any
      // existing holes (one background per image).
      c.commitSpotlight(out);
    } else {
      c.commitDrawable(out);
    }
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

  /// Returns the toolbar's measuring key, and (once) schedules the exact
  /// horizontal centering after the first layout: the seed position only
  /// ESTIMATES the bar's width, which drifts with the tool set (e.g. the
  /// single-tool record bar). One-shot by design: later width changes never
  /// re-center, and a user drag is never overridden.
  GlobalKey _centerToolbarOnce() {
    if (!_toolbarCentered) {
      _toolbarCentered = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final w = _toolbarKey.currentContext?.size?.width;
        setState(() {
          if (w != null && w > 0) {
            _toolbarPos = Offset(
              ((widget.host.size.width - w) / 2)
                  .clamp(0.0, widget.host.size.width - 80),
              _toolbarPos.dy,
            );
          }
          // Reveal even when measuring failed - never leave it invisible.
          _toolbarPlaced = true;
        });
      });
    }
    return _toolbarKey;
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

  /// Loupe placement for [cur] (cursor) within [box]: which EDGE to anchor so the
  /// glass keeps a constant [gap] from the reticle regardless of the info blocks'
  /// size. Anchors the glass's LEFT (loupe right of the cursor) or RIGHT (flipped
  /// left, blocks then right-aligned), and TOP (below) or BOTTOM (flipped up, the
  /// stack reversed so the glass stays nearest the cursor). Using right/bottom
  /// anchors keeps the glass-to-cursor margin identical in every orientation.
  ({double? left, double? right, double? top, double? bottom,
    CrossAxisAlignment cross, bool flipV}) _loupePlacement(Offset cur, Size box) {
    const gap = 24.0;
    final size = widget.loupe.box;
    final tall = size + _loupeBelowReserve();
    final goRight = cur.dx + gap + size <= box.width;
    final goDown = cur.dy + gap + tall <= box.height;
    return (
      left: goRight ? cur.dx + gap : null,
      right: goRight ? null : box.width - (cur.dx - gap),
      top: goDown ? cur.dy + gap : null,
      bottom: goDown ? null : box.height - (cur.dy - gap),
      cross: goRight ? CrossAxisAlignment.start : CrossAxisAlignment.end,
      flipV: !goDown,
    );
  }

  /// The annotation layer, masked to the image rect for the editor (so a drawing
  /// dragged past the edge is hidden + clipped on export) and left unwrapped for
  /// the overlay (full-screen, structurally identical).
  Widget _annotationLayer(bool inCrop) {
    final layer = CustomPaint(
      painter: DrawablePainter(
        // Annotations always paint (so an inactive display still shows its
        // drawings); the selection highlight is a SEPARATE animated layer
        // (see [_selectionHighlight]) so marching ants don't re-rasterize this.
        drawables: _effectiveDrawables(),
        effectImage: _lookupEffect,
        // The magnify tool samples the base image directly.
        baseImage: _interactive
            ? (c.document.value.canvasImage ?? widget.host.baseImage)
            : widget.host.baseImage,
        baseScale: widget.host.pixelScale,
        spotlightImage: _spotlightLayerImage(),
      ),
      size: _canvasSize,
    );
    return _interactive ? ClipRect(child: layer) : layer;
  }

  /// The selected drawable's flowing highlight, in its own layer so it can
  /// animate without re-rasterizing the annotation content. One child either way
  /// (an empty box when nothing is selected), keeping the Stack child count stable.
  Widget _selectionHighlight(bool inCrop) {
    final selIdx = (!_active || inCrop || _editingText)
        ? null
        : c.selectedIndex.value;
    final drawables = _effectiveDrawables();
    final selected = (selIdx != null && selIdx >= 0 && selIdx < drawables.length)
        ? drawables[selIdx]
        : null;
    if (selected == null) return const SizedBox.shrink();
    return IgnorePointer(
      child: CustomPaint(
        size: _canvasSize,
        // Handles (and thus handle-dragging) only for a PINNED (clicked)
        // selection; a hover preview is outline-only.
        painter: SelectionHighlightPainter(
          selected: selected,
          march: _march,
          showHandles: _pinned,
        ),
      ),
    );
  }

  /// The editor's pixel loupe, positioned in SCREEN space at the cursor's
  /// bottom-right (flipping near the window edges so it stays on-screen). It can
  /// float over the checkerboard margin; the content magnifies the canvas around
  /// the logical cursor.
  Widget _editorLoupe(EditorViewport v) {
    final size = widget.loupe.box;
    final cs = v.toLocal(_cursor); // cursor in screen coords
    final p = _loupePlacement(cs, _lastBoxSize);
    return Positioned(
      left: p.left,
      right: p.right,
      top: p.top,
      bottom: p.bottom,
      child: IgnorePointer(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: p.cross,
          children: _loupeColumn(
            CustomPaint(
              size: Size(size, size),
              painter: LoupePainter(
                image: _canvasImage,
                cursorLogical: _cursor,
                scaleFactor: widget.host.pixelScale,
                zoom: widget.loupe.zoom.toDouble(),
                drawables: _effectiveDrawables(),
                effectImage: _lookupEffect,
                logicalSize: _canvasSize,
                dark: MediaQuery.platformBrightnessOf(context) ==
                    Brightness.dark,
              ),
            ),
            flipUp: p.flipV,
          ),
        ),
      ),
    );
  }

  /// Logical -> native px (the readouts show native pixels, matching the loupe's
  /// pixel grid + the saved image).
  int _toPx(double v) => (v * widget.host.pixelScale).round();

  /// The loupe readout — the cursor's current pixel position. The box size +
  /// drag-start are shown at the selection's corner instead (see [BoxSizeLabel]),
  /// not stacked under the loupe.
  /// The AIMED pixel: round(x - 0.5) matches the loupe's snapped center cell
  /// exactly — floor for interior positions, but stable when the cursor sits
  /// exactly on a pixel boundary (integer macOS positions on a 2x display),
  /// where press jitter made floor() flip cells (see LoupePainter).
  int _toPxAimed(double v) => (v * widget.host.pixelScale - 0.5).round();

  // Live-select loupe: the latest span×span live patch around the aim, fetched
  // from the native per-display stream (the frozen loupe samples its frozen
  // image; a live session has no pixels without this).
  ui.Image? _liveLoupeImg;
  Offset? _liveLoupeAt;
  bool _liveLoupeFetching = false;
  // LIVE refresh: the native stream runs at 30 fps regardless; this timer
  // re-samples the patch under a STATIONARY cursor so the loupe tracks the
  // moving screen, not just the moving mouse. Tiny: span²×4 bytes (~576 B
  // at the default span) per tick, only while the live session is up.
  Timer? _liveLoupeTimer;

  void _startLiveLoupeTimer() {
    _liveLoupeTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      if (!_active || !_overCanvas) return;
      _liveLoupeAt = null; // force a re-fetch at the current cursor
      _maybeFetchLiveLoupe();
    });
  }

  void _maybeFetchLiveLoupe() {
    final fetch = widget.host.liveLoupeSample;
    if (fetch == null || _liveLoupeFetching || _cursor == _liveLoupeAt) return;
    _liveLoupeFetching = true;
    final at = _cursor;
    final span = widget.loupe.span;
    fetch(_toPxAimed(at.dx), _toPxAimed(at.dy), span).then((bytes) async {
      ui.Image? img;
      if (bytes != null && bytes.length == span * span * 4) {
        final completer = Completer<ui.Image>();
        ui.decodeImageFromPixels(
            bytes, span, span, ui.PixelFormat.rgba8888, completer.complete);
        img = await completer.future;
      }
      _liveLoupeFetching = false;
      if (!mounted) {
        img?.dispose();
        return;
      }
      if (img != null) {
        setState(() {
          _liveLoupeImg?.dispose();
          _liveLoupeImg = img;
          _liveLoupeAt = at;
        });
      } else {
        _liveLoupeAt = at; // no frame yet; keep whatever we had
      }
      if (_cursor != at) _maybeFetchLiveLoupe(); // chase the moving aim
    }).catchError((_) {
      _liveLoupeFetching = false;
    });
  }

  /// The overlay's crosshair-bound loupe. Frozen sessions magnify the canvas
  /// image; a live-select session magnifies the latest live patch from the
  /// native stream (same painter, so the grid / center marker / frame are
  /// identical). Hidden until the live stream delivers its first patch.
  Widget _overlayLoupe() {
    final live = widget.host.liveSelect;
    if (live) _maybeFetchLiveLoupe();
    final ui.Image image;
    final Offset center;
    if (live) {
      final patch = _liveLoupeImg;
      if (patch == null) return const SizedBox.shrink();
      image = patch;
      // Aim at the patch's center cell: the fetch centered the patch on the
      // aimed pixel, so the painter's snapped center must land on cell
      // span/2 (whose pixel-center coordinate is span/2 + 0.5).
      center = Offset.zero +
          Offset(
            (widget.loupe.span / 2 + 0.5) / widget.host.pixelScale,
            (widget.loupe.span / 2 + 0.5) / widget.host.pixelScale,
          );
    } else {
      image = _canvasImage;
      center = _cursor;
    }
    final p = _loupePlacement(_cursor, _canvasSize);
    return Positioned(
      left: p.left,
      right: p.right,
      top: p.top,
      bottom: p.bottom,
      child: IgnorePointer(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: p.cross,
          children: _loupeColumn(
            CustomPaint(
              size: Size(widget.loupe.box, widget.loupe.box),
              painter: LoupePainter(
                image: image,
                cursorLogical: center,
                scaleFactor: widget.host.pixelScale,
                zoom: widget.loupe.zoom.toDouble(),
                drawables: live ? const [] : _effectiveDrawables(),
                effectImage: live ? null : _lookupEffect,
                logicalSize: live
                    ? Size.zero
                    : Size(_canvasSize.width, _canvasSize.height),
                dark: MediaQuery.platformBrightnessOf(context) ==
                    Brightness.dark,
              ),
            ),
            flipUp: p.flipV,
          ),
        ),
      ),
    );
  }

  /// Apply the persisted loupe info mode ([LoupeConfig.infoMode]) to the
  /// process-global cycle, but only until the user first cycles it this process
  /// — after that the live value owns it (and is persisted on every change), so
  /// a Settings-close hot-reload never clobbers an in-session choice.
  void _restoreLoupeInfoMode() {
    if (!_loupeInfoModeUserSet) _loupeInfoMode = widget.loupe.infoMode;
  }

  /// The blocks under the loupe glass, per the CUMULATIVE [_loupeInfoMode] cycle
  /// (`?` / `/`): coordinates always (until hidden), then the element level, then
  /// the shortcuts, then nothing. The level + shortcuts blocks only apply while
  /// element snap is active for a snap tool.
  List<Widget> _loupeBlocks() {
    if (_loupeInfoMode == LoupeInfoMode.hidden) return const [];
    final elementMode = _elementSnapOn && _snapTools.contains(c.tool.value);
    final showLevel =
        elementMode && _loupeInfoMode.index >= LoupeInfoMode.level.index;
    final showShortcuts =
        elementMode && _loupeInfoMode.index >= LoupeInfoMode.shortcuts.index;
    return [
      _loupeReadout(),
      if (showLevel) _levelBlock(),
      if (showShortcuts) _shortcutsBlock(),
    ];
  }

  /// The loupe column's children: the glass plus the info blocks, 6px-separated,
  /// LEFT-aligned so the glass stays put regardless of a wider block. When the
  /// loupe is flipped ABOVE the cursor ([flipUp]) the whole stack is reversed
  /// (blocks above, glass at the bottom) so the glass stays nearest the cursor.
  List<Widget> _loupeColumn(Widget glass, {required bool flipUp}) {
    final items = [glass, ..._loupeBlocks()];
    final ordered = flipUp ? items.reversed.toList() : items;
    return [
      for (var i = 0; i < ordered.length; i++) ...[
        if (i > 0) const SizedBox(height: 6),
        ordered[i],
      ],
    ];
  }

  /// The element-snap LEVEL block (its own pill): the current tree level.
  Widget _levelBlock() {
    final l = AppLocalizations.of(context);
    final w = _elementWalk;
    final lvl = w == 0
        ? l.elementSnapLevelDefault
        : w > 0
            ? l.elementSnapLevelOut(w)
            : l.elementSnapLevelIn(-w);
    return LoupeLevelBlock(text: l.elementSnapLevelLabel(lvl));
  }

  /// The SHORTCUTS block (its own left-aligned pill): the aiming-stage shortcuts
  /// not shown in the toolbar — element walk, arrow nudge, Shift angle snap.
  Widget _shortcutsBlock() {
    final l = AppLocalizations.of(context);
    return LoupeShortcutsBlock(rows: [
      (l.loupeShortcutWalkKey, l.loupeShortcutWalkDesc),
      (l.loupeShortcutNudgeKey, l.loupeShortcutNudgeDesc),
      (l.loupeShortcutAngleKey, l.loupeShortcutAngleDesc),
    ]);
  }

  /// Vertical space the visible loupe blocks need (for the edge-flip clamp):
  /// nothing when hidden, the readout reserve for coords, plus the level /
  /// shortcuts blocks when the cumulative mode reveals them.
  double _loupeBelowReserve() {
    if (_loupeInfoMode == LoupeInfoMode.hidden) return 0;
    final elementMode = _elementSnapOn && _snapTools.contains(c.tool.value);
    var r = _kLoupeReadoutReserve;
    if (elementMode && _loupeInfoMode.index >= LoupeInfoMode.level.index) r += 30;
    if (elementMode && _loupeInfoMode.index >= LoupeInfoMode.shortcuts.index) {
      r += 56;
    }
    return r;
  }

  Widget _loupeReadout() => LoupeReadout(
        x: _toPxAimed(_cursor.dx),
        y: _toPxAimed(_cursor.dy),
        color: _eyedropper ? _pixelColorAt(_cursor) : null,
        copied: _eyedropper ? _copiedFormat : null,
      );

  /// A small eyedropper glyph pinned to the lower-right of the aim reticle while
  /// sampling. The eyedropper reuses the region-tool crosshair/reticle/loupe HUD,
  /// which alone looks identical to crop — this badge makes "picking a colour"
  /// unmistakable so it never reads as a tool switch. [at] is the reticle point in
  /// the host stack's coordinate space (canvas-local for the overlay, screen-local
  /// for the editor).
  Widget _eyedropperBadge(Offset at) => Positioned(
        left: at.dx + 11,
        top: at.dy + 11,
        child: const IgnorePointer(
          child: Icon(
            Icons.colorize,
            size: 18,
            color: Color(0xFFFFFFFF),
            shadows: [Shadow(color: Color(0xCC000000), blurRadius: 3)],
          ),
        ),
      );

  /// The same badge language for pin mode: a small pin glyph at the reticle's
  /// lower-right while the crop slot (= the pin region selector there) is
  /// aimed, so "selecting what to pin" never reads as a normal crop/export.
  /// Overlay only — pin mode never exists in the standalone editor.
  Widget _pinBadge(Offset at) => Positioned(
        left: at.dx + 11,
        top: at.dy + 11,
        child: const IgnorePointer(
          child: Icon(
            Icons.push_pin,
            size: 18,
            color: Color(0xFFFFFFFF),
            shadows: [Shadow(color: Color(0xCC000000), blurRadius: 3)],
          ),
        ),
      );

  /// The record-mode aim badge (videocam beside the reticle) — the pin
  /// badge's language for the recording live-select session.
  Widget _recordBadge(Offset at) => Positioned(
        left: at.dx + 11,
        top: at.dy + 11,
        child: const IgnorePointer(
          child: Icon(
            Icons.videocam,
            size: 18,
            color: Color(0xFFFFFFFF),
            shadows: [Shadow(color: Color(0xCC000000), blurRadius: 3)],
          ),
        ),
      );

  // Vertical space reserved below the loupe for the readout, so the loupe flips
  // above the cursor early enough that the readout stays on-screen too.
  static const double _kLoupeReadoutReserve = 64.0;

  /// The editor's two crop readouts, in SCREEN space (viewport-mapped) so their
  /// text stays a constant size under zoom (unlike the canvas-space scrim/handles).
  List<Widget> _editorBoxLabel(EditorViewport v) => _cropReadoutLabels(
    _crop.rect.value!,
    (p) => Offset(v.offset.dx + p.dx * v.scale, v.offset.dy + p.dy * v.scale),
    _lastBoxSize,
  );

  /// The two crop readout pills: the drag-start coordinate beside the START corner
  /// (the anchor) and the W×H beside the OPPOSITE (cursor) corner. [map] converts a
  /// canvas-space point into the host Stack's coordinate space (identity for the
  /// 1:1 overlay; viewport-mapped for the zoomable editor); [bound] clamps the pill
  /// anchor on-screen. Values are native px.
  List<Widget> _cropReadoutLabels(
    Rect rect,
    Offset Function(Offset) map,
    Size bound,
  ) {
    final a = _crop.anchor ?? rect.topLeft;
    final anchorLeft = a.dx <= rect.center.dx;
    final anchorTop = a.dy <= rect.center.dy;
    final anchorPt = map(
      Offset(anchorLeft ? rect.left : rect.right, anchorTop ? rect.top : rect.bottom),
    );
    final cursorPt = map(
      Offset(anchorLeft ? rect.right : rect.left, anchorTop ? rect.bottom : rect.top),
    );
    return [
      _cornerPill(
        corner: anchorPt,
        isLeft: anchorLeft,
        isTop: anchorTop,
        bound: bound,
        child: StartCoordLabel(
          startX: _toPx(a.dx),
          startY: _toPx(a.dy),
          cornerLeft: anchorLeft,
          cornerTop: anchorTop,
        ),
      ),
      _cornerPill(
        corner: cursorPt,
        isLeft: !anchorLeft,
        isTop: !anchorTop,
        bound: bound,
        child: BoxSizeLabel(w: _toPx(rect.width), h: _toPx(rect.height)),
      ),
    ];
  }

  /// Place a HUD pill at the selection's [corner]: HUGGING the box edge
  /// horizontally (left edge to the box's left for a left corner, right edge to the
  /// box's right for a right corner) and just OUTSIDE the box vertically (above a
  /// top corner, below a bottom corner). Vertical-outside keeps it clear of the
  /// loupe, which tracks the cursor to the side. Edge alignment uses a
  /// [FractionalTranslation] of the pill's own size; a fixed gap nudges it off the
  /// edge.
  Widget _cornerPill({
    required Offset corner,
    required bool isLeft,
    required bool isTop,
    required Size bound,
    required Widget child,
  }) {
    const gap = 6.0;
    return Positioned(
      left: corner.dx.clamp(0.0, bound.width),
      top: corner.dy.clamp(0.0, bound.height),
      child: FractionalTranslation(
        translation: Offset(isLeft ? 0.0 : -1.0, isTop ? -1.0 : 0.0),
        child: Padding(
          padding: EdgeInsets.only(
            bottom: isTop ? gap : 0,
            top: isTop ? 0 : gap,
          ),
          child: child,
        ),
      ),
    );
  }

  /// The ✔/✖ confirm bar for a pending crop-trim, positioned just below the
  /// selection's on-screen (viewport-mapped) bottom-right and clamped on-screen.
  Widget _cropConfirmButtons(EditorViewport v) {
    final r = _crop.rect.value!;
    final screenRight = v.offset.dx + r.right * v.scale;
    final screenBottom = v.offset.dy + r.bottom * v.scale;
    const gap = 8.0, barH = 52.0;
    // Stack the bar below the box, RIGHT-ALIGNED to the box's right edge so it
    // lines up with the W×H readout pill above it. Anchored by its OWN right edge
    // (FractionalTranslation) so the exact bar width doesn't matter; pushed down by
    // the readout's height so the two don't overlap.
    const readoutClearance = 30.0;
    return Positioned(
      left: screenRight.clamp(gap, _lastBoxSize.width - gap),
      top: (screenBottom + gap + readoutClearance)
          .clamp(gap, _lastBoxSize.height - barH - gap),
      child: FractionalTranslation(
        translation: const Offset(-1, 0),
        child: _CropConfirmBar(
          onConfirm: _confirmTrim,
          onCancel: () => setState(() {
            _crop.clear();
            _cropping = false;
          }),
        ),
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
    // The precision crosshair + loupe show on the active display. For the editor
    // they ALSO require the cursor to be over the image (or mid-gesture): off the
    // image they hide instead of freezing at the edge. The overlay is full-screen,
    // so this is always satisfied there.
    final showHud =
        _active &&
        (showsCrosshair || _eyedropper) &&
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
    // Marching ants run only while a dashed HUD element is shown AND the user has
    // not turned the animation off (then the dashes are static). A selection
    // highlight can also be visible without the crosshair, so include it.
    final hasSelection = _active && !inCrop && !_editingText &&
        c.selectedIndex.value != null;
    _syncMarch(
      widget.hud.marchingAnts &&
          (showHud || snapTarget != null || hasSelection),
    );
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
      // trackpad pinch = zoom. The overlay normally has no viewport, but element
      // snap also needs the wheel (walk the AX tree), so wire it then too;
      // _onPointerSignal handles the element-snap branch before the viewport one.
      onPointerSignal:
          (_interactive || _elementSnapOn) ? _onPointerSignal : null,
      // Element snap also needs the trackpad two-finger pan (walk the AX tree);
      // _onPanZoomUpdate handles the element-snap branch before the zoom one.
      onPointerPanZoomStart:
          (_interactive || _elementSnapOn) ? _onPanZoomStart : null,
      onPointerPanZoomUpdate:
          (_interactive || _elementSnapOn) ? _onPanZoomUpdate : null,
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
                cursor:
                    (_eyedropper ||
                        (_active && !_editingText && !_isSelectTool))
                    ? SystemMouseCursors.none
                    : SystemMouseCursors.basic,
                onEnter: (_) => setState(() => _overCanvas = true),
                onExit: (_) => setState(() => _overCanvas = false),
                onHover: _onHover,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  // Anchor a drag at the actual pointer-DOWN point, not where the
                  // pan won the arena. With the default `.start`, onPanStart's
                  // position is down + the movement accumulated before acceptance
                  // (large on a FAST drag, since coalesced moves can jump far before
                  // the pan beats the tap), so the region's start corner landed
                  // away from the aimed click. `.down` reports the true down point
                  // and feeds that accumulated delta through the first onPanUpdate.
                  dragStartBehavior: DragStartBehavior.down,
                  // Exclude trackpad in BOTH modes: a two-finger trackpad scroll
                  // arrives as a pan gesture, and if the recognizer accepts it the
                  // editor would zoom-as-draw and the overlay would start a marquee
                  // box-selection. A single-finger click-drag (how a laptop draws)
                  // reports as mouse-kind, so marquee/draw still works.
                  supportedDevices: _kDrawDevices,
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
                // a border + drop shadow on the checkerboard (owner's image card),
                // sized to the logical canvas inside the viewport transform. SQUARE
                // corners: a rounded clip would hide the image's own corner pixels
                // (the displayed image must stay faithful to the source).
                RepaintBoundary(
                  child: _interactive
                      ? Container(
                          width: _canvasSize.width,
                          height: _canvasSize.height,
                          decoration: BoxDecoration(
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
                          child: RawImage(
                            image: _canvasImage,
                            width: _canvasSize.width,
                            height: _canvasSize.height,
                            fit: BoxFit.fill,
                          ),
                        )
                      : RawImage(
                          image: widget.host.baseImage,
                          fit: BoxFit.fill,
                        ),
                ),
                // Layer 2: annotation layer (+ a highlight box on the hovered/selected
                // drawable in the annotate phase). For the editor it is MASKED to the
                // image rect: a drawing can be dragged past the edge (over the
                // checkerboard) but the out-of-bounds part is hidden (and clipped on
                // export). Only this layer is clipped, so the base image keeps its
                // drop shadow. The overlay is unwrapped (structurally identical).
                // Cursor layer (overlay, toggled on): the captured OS pointer,
                // treated as part of the base image — between the frozen frame and
                // the annotations. Non-interactive (IgnorePointer, never hit-tested).
                if (c.showCursor.value &&
                    widget.host.cursorImage != null &&
                    widget.host.cursorTopLeft != null)
                  Positioned(
                    left: widget.host.cursorTopLeft!.dx,
                    top: widget.host.cursorTopLeft!.dy,
                    child: IgnorePointer(
                      child: RawImage(
                        image: widget.host.cursorImage,
                        width:
                            widget.host.cursorImage!.width / widget.host.pixelScale,
                        height: widget.host.cursorImage!.height /
                            widget.host.pixelScale,
                      ),
                    ),
                  ),
                RepaintBoundary(child: _annotationLayer(inCrop)),
                // Selection highlight (flowing marching-ants outline + handles),
                // separate from the annotation layer so it animates cheaply.
                _selectionHighlight(inCrop),
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
                            // Marching outline in its own layer so the cheap line
                            // redraw — not the costly scrim — repaints each frame.
                            CustomPaint(
                              painter: SelectionBorderPainter(
                                selection: rect,
                                march: _march,
                              ),
                            ),
                            // Editor: corner handles on a pending selection so it
                            // can be resized/moved before confirming the trim.
                            if (widget.host.cropTrims && !_cropping)
                              CustomPaint(
                                painter: _CropHandlesPainter(rect),
                              ),
                            // Crop readouts: drag-start coordinate beside the start
                            // corner, W×H beside the cursor corner (native px).
                            // Overlay only — canvas == screen (1:1); the editor
                            // draws them in SCREEN space (constant size under zoom)
                            // via [_editorBoxLabel].
                            if (!_interactive)
                              ..._cropReadoutLabels(
                                rect,
                                (p) => p,
                                _canvasSize,
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
                                : WindowHighlightPainter(rect, march: _march),
                          ),
                        ),
                      ),
                // Precision HUD: full-screen crosshair + pixel loupe — crop and the
                // raster region tools (blur/pixelate), active display only. OVERLAY
                // only (canvas-space); the editor renders its HUD in the outer
                // stack (screen-space) so it floats over the whole window.
                if (showHud && !_interactive && widget.hud.crosshair)
                  IgnorePointer(
                    child: CustomPaint(
                      size: _canvasSize,
                      painter: CrosshairPainter(
                        _cursor,
                        march: _march,
                        hole: kReticleArm + 3,
                      ),
                    ),
                  ),
                // Centre reticle for the region tools — always shown with the HUD,
                // independent of the crosshair-lines toggle, so there's always a
                // precise aim point at the cursor.
                if (showHud && !_interactive)
                  IgnorePointer(
                    child: CustomPaint(
                      size: _canvasSize,
                      painter: ReticlePainter(_cursor),
                    ),
                  ),
                // Loupe is bound to the crosshair — shown/hidden together, so it
                // never flickers off when hovering over an existing region.
                if (showHud && !_interactive) _overlayLoupe(),
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
                // Eyedropper badge beside the reticle so colour-sampling mode is
                // visually distinct from the region tools' identical HUD.
                if (_eyedropper && !_interactive) _eyedropperBadge(_cursor),
                // Pin badge beside the reticle while pin mode aims its region
                // selector (the crop slot) — same language as the eyedropper
                // badge. The eyedropper wins when both could apply.
                if (widget.pinMode &&
                    showHud &&
                    !_interactive &&
                    !_eyedropper &&
                    c.tool.value == ToolKind.crop)
                  _pinBadge(_cursor),
                // Record mode aims with the same badge language (videocam).
                if (widget.recordMode &&
                    showHud &&
                    !_interactive &&
                    c.tool.value == ToolKind.crop)
                  _recordBadge(_cursor),
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
                    // Invisible (but laid out) until the one-shot centering
                    // measured it - the seed position must never paint.
                    child: Opacity(
                      opacity: _toolbarPlaced ? 1 : 0,
                      child: Material(
                        key: _centerToolbarOnce(),
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
                          showCursorToggle: widget.host.cursorImage != null,
                          pinMode: widget.pinMode,
                          recordMode: widget.recordMode,
                          recordOverrides: widget.recordOverrides,
                          layerCaption: widget.layerCaption,
                          layerAccent: widget.layerAccent,
                        ),
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
                if (showHud && widget.hud.crosshair)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: CrosshairPainter(
                          v.toLocal(_cursor),
                          march: _march,
                          hole: kReticleArm + 3,
                        ),
                      ),
                    ),
                  ),
                // Centre reticle for region tools (always with the HUD), plus the
                // drawing-tools reticle — both in screen space.
                if (showHud || _showsReticle)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: ReticlePainter(v.toLocal(_cursor)),
                      ),
                    ),
                  ),
                // Eyedropper badge beside the reticle (screen space) — see overlay.
                if (_eyedropper) _eyedropperBadge(v.toLocal(_cursor)),
                if (showHud) _editorLoupe(v),
                // Crop readouts in screen space (constant size under zoom): start
                // coordinate at the start corner, W×H at the cursor corner.
                if (_active && inCrop && _crop.rect.value != null)
                  ..._editorBoxLabel(v),
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
    // Chrome: the shared HUD tier (GlimprTokens.hudBg/hudBorder); the ✔/✖
    // colors stay, same lightness family as the accent so they read in both
    // modes.
    final dark =
        MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final t = GlimprTokens.forBrightness(
        dark ? Brightness.dark : Brightness.light);
    final l = AppLocalizations.of(context);
    return Material(
      type: MaterialType.transparency,
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: t.hudBg,
          borderRadius: BorderRadius.circular(GlimprTokens.radiusMenu),
          border: Border.all(color: t.hudBorder),
          boxShadow: [
            BoxShadow(
              color: dark ? const Color(0x66000000) : const Color(0x2E0F172A),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _CropBtn(
              icon: Icons.check,
              color: const Color(0xFF34D399),
              tooltip: l.editorCropConfirm,
              onTap: onConfirm,
            ),
            const SizedBox(width: 2),
            _CropBtn(
              icon: Icons.close,
              color: const Color(0xFFF87171),
              tooltip: l.editorCropCancel,
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
