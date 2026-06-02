import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import '../capture/capture_bridge.dart';
import '../capture/captured_display.dart';
import '../editor/drawable.dart';
import '../editor/drawable_painter.dart';
import '../editor/editor_controller.dart';
import '../editor/hit_test.dart';
import '../editor/raster.dart';
import '../editor/text_metrics.dart';
import 'crop_hud.dart';
import 'rich_text_controller.dart';
import 'selection_controller.dart';
import 'selection_label.dart';
import 'selection_scrim.dart';
import 'toolbar.dart';
import 'window_snap.dart';

/// In-overlay annotation editor for ONE display. Default tool is Crop; each
/// annotation tool manages only its OWN drawable type (hover highlights, drag
/// moves, tap edits, right-click deletes; right-click also cancels an in-progress
/// draw/crop). Crop dims only once a drag exists and shows a full-screen
/// crosshair + pixel loupe. Local gesture coords == display-local logical coords.
class EditorCanvas extends StatefulWidget {
  final CapturedDisplay display;
  final ui.Image frozenImage; // native pixels — used by the loupe
  final EditorController controller;
  final Future<void> Function(Rect? selectionLogical) onExport;
  final VoidCallback onCancel;
  // Single source of truth for cross-display follow: the native cursor poll
  // pushes (active display id, cursor display-local point) here. This editor is
  // active iff the id matches its own display; on becoming active it seeds the
  // crosshair from the point so the cross lands without a stale frame.
  final ValueListenable<({int id, Offset cursor})> activeSignal;
  const EditorCanvas({
    super.key,
    required this.display,
    required this.frozenImage,
    required this.controller,
    required this.onExport,
    required this.onCancel,
    required this.activeSignal,
  });

  @override
  State<EditorCanvas> createState() => _EditorCanvasState();
}

class _EditorCanvasState extends State<EditorCanvas> {
  final _focus = FocusNode();
  final _crop = SelectionController();
  final _bridge = CaptureBridge();

  late Offset _cursor; // logical cursor (crosshair/loupe/nudge + hover)
  late Offset _toolbarPos; // top-left of the draggable toolbar
  // The cursor is over THIS display -> show the interactive HUD/toolbar here.
  // Follows the mouse across displays; the launch (cursor) display starts active.
  late bool _active;
  // The pointer is over the CANVAS (not the toolbar) -> draw our reticle there
  // and hide the system cursor; over the toolbar we let the normal click cursor
  // show. Driven by the canvas MouseRegion's enter/exit.
  bool _overCanvas = false;
  bool _lastHide = false; // last system-cursor-hidden value pushed to native

  // New-shape preview (drag on empty).
  Drawable? _preview;
  Offset? _dragStart;
  List<Offset>? _penPoints; // accumulated freehand points (pen tool)
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

  bool _cropping = false;

  // Snappable windows for THIS display (capture-time snapshot) + the one the
  // cursor is currently over (crop tool, not mid-drag) — highlighted + snapped.
  List<Rect> _windows = const [];
  Rect? _hoverWindow;
  bool _cancelGesture = false; // right-click cancelled the active drag

  // Inline rich-text editing.
  final _textFocus = FocusNode();
  RichTextController? _richCtl;
  Offset? _textPos;
  int? _editTextIndex; // re-editing an existing text drawable
  bool _editingText = false;

  EditorController get c => widget.controller;
  bool get _inCrop => c.phase.value == EditorPhase.crop;

  /// The whole-display rect (inset so its frame stays fully on-screen) — the
  /// snap target when hovering bare desktop (no window under the cursor).
  Rect get _fullDisplayRect =>
      Rect.fromLTWH(2, 2, widget.display.width - 4, widget.display.height - 4);

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
  bool get _dragging =>
      _cropping || _dragStart != null || _editIndex != null;

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
    final cx = widget.display.cursorX, cy = widget.display.cursorY;
    _cursor = (cx != null && cy != null)
        ? Offset(cx, cy)
        : Offset(widget.display.width / 2, widget.display.height / 2);
    _toolbarPos = Offset(
      widget.display.width / 2 - 160,
      widget.display.height - 120,
    );
    _active = widget.display.isCursorDisplay; // launch display starts active
    _overCanvas = widget.display.isCursorDisplay; // pointer starts over canvas
    _windows = widget.display.windows;
    c.document.addListener(_rebuild);
    c.selectedIndex.addListener(_rebuild);
    c.tool.addListener(_rebuild);
    c.tool.addListener(_onToolChanged);
    c.phase.addListener(_rebuild);
    c.style.addListener(_onStyleChanged);
    _textFocus.addListener(_rebuild); // repaint our selection on focus changes
    widget.activeSignal.addListener(
      _onActiveSignal,
    ); // cursor poll drives active
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    c.document.removeListener(_rebuild);
    c.selectedIndex.removeListener(_rebuild);
    c.tool.removeListener(_rebuild);
    c.tool.removeListener(_onToolChanged);
    c.phase.removeListener(_rebuild);
    c.style.removeListener(_onStyleChanged);
    _textFocus.removeListener(_rebuild);
    widget.activeSignal.removeListener(_onActiveSignal);
    _richCtl?.dispose();
    _focus.dispose();
    _crop.dispose();
    _textFocus.dispose();
    super.dispose();
  }

  /// While editing, a toolbar style change applies to the selected text range
  /// (or sets the style for subsequent typing) instead of the whole object.
  void _onStyleChanged() {
    if (_editingText) {
      _richCtl?.applyStyle(c.style.value.color, c.style.value.fontSize);
    }
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _onToolChanged() {
    // Switching tools commits any in-progress text (its tool is gone). Blur no
    // longer commits, so the pt field can take focus without ending editing.
    if (_editingText) _commitText();
    // Paste is triggered by Cmd-V only; selecting the Paste tool just enters
    // paste mode (to select / move / right-click-delete already-pasted images).
    _ensureRasterFor(c.tool.value); // pre-compute whole-frame blur/pixelate
  }

  /// Compute the whole-frame blur / pixelate ONCE when its tool is first
  /// selected (the region drag then just masks it — no per-frame recompute).
  Future<void> _ensureRasterFor(ToolKind t) async {
    if (t == ToolKind.blur && _blurredFull == null) {
      final img = await blurWhole(
        widget.frozenImage,
        kBlurSigmaLogical * widget.display.scaleFactor,
      );
      if (mounted) setState(() => _blurredFull = img);
    } else if (t == ToolKind.pixelate && _pixelatedFull == null) {
      final img = await pixelateWhole(widget.frozenImage, kPixelCellNative);
      if (mounted) setState(() => _pixelatedFull = img);
    }
  }

  @override
  void didUpdateWidget(EditorCanvas old) {
    super.didUpdateWidget(old);
    // New frozen frame (in-place re-capture) -> the pre-computed images are
    // stale; drop them and recompute for the active tool.
    if (old.frozenImage != widget.frozenImage) {
      _blurredFull = null;
      _pixelatedFull = null;
      _windows = widget.display.windows;
      _hoverWindow = null;
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
    final sig = widget.activeSignal.value;
    final mine = sig.id == widget.display.displayId;
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
      final sf = widget.display.scaleFactor;
      var w = img.width / sf;
      var h = img.height / sf;
      if (w <= 0 || h <= 0) return;
      // Fit within ~half the display, preserving aspect; never upscale.
      final fit = [
        1.0,
        widget.display.width * 0.5 / w,
        widget.display.height * 0.5 / h,
      ].reduce((a, b) => a < b ? a : b);
      w *= fit;
      h *= fit;
      final rect = Rect.fromCenter(
        center: Offset(widget.display.width / 2, widget.display.height / 2),
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
        return (d) => d is ImageDrawable;
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

  int? _hitActiveType(Offset p) =>
      hitTestTop(c.document.value.drawables, p, where: _typeFilter());

  // ---- keyboard ----------------------------------------------------------

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (_editingText) {
      return KeyEventResult.ignored; // text wrapper handles keys
    }
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final key = e.logicalKey;
    final meta = HardwareKeyboard.instance.isMetaPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;

    if (key == LogicalKeyboardKey.escape) {
      if (_inCrop && _cropping) {
        setState(() {
          _crop.clear();
          _cropping = false;
        });
        return KeyEventResult.handled;
      }
      widget.onCancel();
      return KeyEventResult.handled;
    }

    if (meta && key == LogicalKeyboardKey.keyZ) {
      shift ? c.redo() : c.undo();
      c.selectedIndex.value = null;
      return KeyEventResult.handled;
    }

    if (meta && key == LogicalKeyboardKey.keyV) {
      _pasteImage();
      return KeyEventResult.handled;
    }

    if ((key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter) &&
        !_inCrop) {
      widget.onExport(null); // annotate phase, no crop -> whole display
      return KeyEventResult.handled;
    }

    if ((key == LogicalKeyboardKey.delete ||
            key == LogicalKeyboardKey.backspace) &&
        c.selectedIndex.value != null) {
      c.deleteSelected();
      return KeyEventResult.handled;
    }

    // Tool shortcuts (mirror EditorToolbar.tools): region tools on letters
    // (C=Crop B=Blur P=Pixelate, below); the drawing tools on digits 1-9.
    const order = [
      ToolKind.rectangle, // 1
      ToolKind.ellipse, // 2
      ToolKind.line, // 3
      ToolKind.arrow, // 4
      ToolKind.pen, // 5
      ToolKind.text, // 6
      ToolKind.highlighter, // 7
      ToolKind.step, // 8
      ToolKind.paste, // 9
    ];
    const digits = [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5,
      LogicalKeyboardKey.digit6,
      LogicalKeyboardKey.digit7,
      LogicalKeyboardKey.digit8,
      LogicalKeyboardKey.digit9,
    ];
    final di = digits.indexOf(key);
    if (di != -1) {
      c.selectTool(order[di]);
      return KeyEventResult.handled;
    }
    // Letter shortcuts for the region tools. Guarded by !meta and the
    // _editingText early-return above, so typing is never hijacked.
    if (!meta) {
      if (key == LogicalKeyboardKey.keyC) {
        c.selectTool(ToolKind.crop);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyB) {
        c.selectTool(ToolKind.blur);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyP) {
        c.selectTool(ToolKind.pixelate);
        return KeyEventResult.handled;
      }
    }

    // Arrow-nudge for the region tools (crop + blur/pixelate): move the crosshair
    // by ONE PHYSICAL pixel (= 1 / scaleFactor logical points — a single pixel on
    // Retina, not 2-3) and warp the OS cursor to match so a later physical move
    // continues from the nudged point. Also nudges the in-progress region's
    // dragging corner.
    if (_showsCrosshair) {
      final step = 1.0 / widget.display.scaleFactor;
      Offset? delta;
      if (key == LogicalKeyboardKey.arrowLeft) delta = Offset(-step, 0);
      if (key == LogicalKeyboardKey.arrowRight) delta = Offset(step, 0);
      if (key == LogicalKeyboardKey.arrowUp) delta = Offset(0, -step);
      if (key == LogicalKeyboardKey.arrowDown) delta = Offset(0, step);
      if (delta != null) {
        final next = Offset(
          (_cursor.dx + delta.dx).clamp(0.0, widget.display.width),
          (_cursor.dy + delta.dy).clamp(0.0, widget.display.height),
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
        _bridge.warpCursor(
          widget.display.left + next.dx,
          widget.display.top + next.dy,
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
    final ctl = RichTextController(
      color: c.style.value.color,
      size: c.style.value.fontSize,
    )..addListener(_rebuild);
    setState(() {
      _richCtl = ctl;
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
    final ctl = RichTextController.fromRuns(
      d.runs,
      color: c.style.value.color,
      size: c.style.value.fontSize,
    )..addListener(_rebuild);
    setState(() {
      _richCtl = ctl;
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
    final ctl = _richCtl;
    final idx = _editTextIndex;
    if (pos != null && ctl != null) {
      if (ctl.text.trim().isNotEmpty) {
        final d = TextDrawable(pos, ctl.toRuns(), c.style.value);
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
    final old = _richCtl;
    old?.removeListener(_rebuild);
    setState(() {
      _editingText = false;
      _textPos = null;
      _editTextIndex = null;
      _richCtl = null;
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

  void _onHover(PointerHoverEvent e) {
    final p = e.localPosition;
    setState(() => _cursor = p);
    if (_inCrop) return;
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
    final p = d.localPosition;
    // Window-snap (ShareX-style): a tap on a window applies the snap tool to that
    // window's bounds — crop captures it; blur/pixelate/rectangle/ellipse add a
    // drawable spanning it. With NO window under the cursor the tools fall back
    // to their normal tap (crop -> whole display; the rest select).
    final win = topmostWindowAt(_windows, p);
    final style = c.style.value;
    switch (c.tool.value) {
      case ToolKind.crop:
        widget.onExport(win); // null window -> whole display
        return;
      case ToolKind.blur:
        if (win != null) {
          c.commitDrawable(BlurDrawable(win, style));
        } else {
          c.selectedIndex.value = _hitActiveType(p);
        }
        return;
      case ToolKind.pixelate:
        if (win != null) {
          c.commitDrawable(PixelateDrawable(win, style));
        } else {
          c.selectedIndex.value = _hitActiveType(p);
        }
        return;
      case ToolKind.rectangle:
        if (win != null) {
          c.commitDrawable(RectangleDrawable(win, style));
        } else {
          c.selectedIndex.value = _hitActiveType(p);
        }
        return;
      case ToolKind.ellipse:
        if (win != null) {
          c.commitDrawable(EllipseDrawable(win, style));
        } else {
          c.selectedIndex.value = _hitActiveType(p);
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
          c.selectedIndex.value = idx;
        }
        return;
      case ToolKind.arrow:
      case ToolKind.line:
      case ToolKind.pen:
      case ToolKind.highlighter:
      case ToolKind.paste:
        c.selectedIndex.value = _hitActiveType(p);
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
      _onRightDown(e.localPosition);
    } else if (!right) {
      _rightLatched = false;
    }
  }

  /// Track the crosshair from the raw pointer stream (outermost Listener), so it
  /// follows everywhere on the active display — over the toolbar, and while the
  /// left button is still held after a right-click cancel.
  void _trackCursor(PointerEvent e) {
    if (!_active) return;
    final p = e.localPosition;
    // Window-snap: highlight the top-most window under the cursor for the snap
    // tools (crop/blur/pixelate/rectangle/ellipse), but not while dragging. The
    // full-screen crosshair / reticle follow the pointer on the active display.
    final hover = (_snapTools.contains(c.tool.value) && !_dragging)
        ? topmostWindowAt(_windows, p)
        : null;
    setState(() {
      _cursor = _clampToDisplay(p);
      _hoverWindow = hover;
    });
  }

  /// True when our small reticle should show: an active drawing tool (not a
  /// region tool, which uses the full crosshair) with the pointer over the canvas
  /// and no inline text edit in progress.
  bool get _showsReticle =>
      _active && !_showsCrosshair && _overCanvas && !_editingText;

  /// Hide the system cursor whenever we're drawing OUR own cursor (crosshair or
  /// reticle) over the canvas, or while dragging (the drag may briefly stray off
  /// the display before the confine warps it back). Show it over the toolbar and
  /// while editing text. Only the active engine drives the (app-global) state;
  /// pushed on change. Called from build so any setState reconciles it.
  void _syncCursorHidden() {
    final hide =
        _active &&
        !_editingText &&
        (_overCanvas || _dragStart != null || _editIndex != null || _cropping);
    if (hide != _lastHide) {
      _lastHide = hide;
      _bridge.setCursorHidden(hide);
    }
  }

  /// Clamp a position to this display's bounds. During a drag the (hidden)
  /// hardware cursor can wander onto another display — we freeze the cross-display
  /// handoff natively rather than warp the cursor each frame (which jittered), so
  /// clamping keeps the crosshair / marquee pinned cleanly at the edge.
  Offset _clampToDisplay(Offset p) => Offset(
    p.dx.clamp(0.0, widget.display.width),
    p.dy.clamp(0.0, widget.display.height),
  );

  void _onRightDown(Offset p) {
    // While editing text, right-click just commits the in-progress text — it
    // does NOT delete/exit, which would discard the unfinished text.
    if (_editingText) {
      _commitText();
      return;
    }
    // Right-click is contextual (priority order):
    //  1) a gesture in progress -> CANCEL it (crop drag clears the selection; a
    //     draw / move / resize reverts) and stay in capture;
    //  2) over an existing drawable (ANY type) -> DELETE it and stay;
    //  3) otherwise (empty space) -> EXIT the capture, like Esc.
    // The any-type hit-test in (2) is what makes "only empty space exits" hold
    // for every tool — incl. Crop and a tool whose type differs from the drawable
    // under the cursor (those would otherwise wrongly fall through to exit).
    if (_cropping ||
        _dragStart != null ||
        _preview != null ||
        _editIndex != null) {
      _bridge.setDrawingLock(false); // release the cursor confine
      setState(() {
        _cancelGesture = true; // a pending pan-end must not commit
        _crop.clear();
        _cropping = false;
        _resetDrawState();
        _resetEditState();
      });
      return;
    }
    final idx = hitTestTop(c.document.value.drawables, p);
    if (idx != null) {
      c.document.value = c.document.value.removeAt(idx);
      c.selectedIndex.value = null;
      return;
    }
    widget.onCancel(); // empty space -> exit capture
  }

  void _resetDrawState() {
    _preview = null;
    _dragStart = null;
    _penPoints = null;
  }

  void _resetEditState() {
    _editIndex = null;
    _editOriginal = null;
    _editPreview = null;
    _moveStart = null;
    _resizeCorner = null;
  }

  void _panStart(DragStartDetails d) {
    _cancelGesture = false;
    // A drag begins: confine the cursor to this display so the stroke can't be
    // broken by the pointer straying onto another display (released in _panEnd /
    // _panCancel). Spanning across displays is out of scope.
    _bridge.setDrawingLock(true);
    final p = d.localPosition;
    if (c.tool.value == ToolKind.crop) {
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
    } else {
      _dragStart = p; // start drawing a new same-type drawable (not for text)
      _preview = null;
      // Pen accumulates the stroke's points as the drag proceeds.
      if (c.tool.value == ToolKind.pen) _penPoints = [p];
    }
  }

  void _panUpdate(DragUpdateDetails d) {
    // Clamp to this display so a drag that pushes past the edge keeps the
    // marquee / shape / crosshair pinned at the boundary (the hardware cursor is
    // free but the active handoff is frozen while dragging).
    final p = _clampToDisplay(d.localPosition);
    if (_cancelGesture) {
      // Right-click cancelled this drag: keep the crosshair tracking the mouse
      // while the left button is still held (no jank if the two buttons aren't
      // released together); a new selection needs a fresh left press.
      if (_showsCrosshair) setState(() => _cursor = p);
      return;
    }
    if (c.tool.value == ToolKind.crop) {
      setState(() => _cursor = p);
      _crop.update(p);
      return;
    }
    if (_editIndex != null) {
      _updateSelectDrag(p);
      return;
    }
    final s = _dragStart;
    if (s == null) return;
    switch (c.tool.value) {
      case ToolKind.rectangle:
        setState(
          () => _preview = RectangleDrawable(
            Rect.fromPoints(s, p),
            c.style.value,
          ),
        );
        break;
      case ToolKind.ellipse:
        setState(
          () =>
              _preview = EllipseDrawable(Rect.fromPoints(s, p), c.style.value),
        );
        break;
      case ToolKind.arrow:
        setState(() => _preview = ArrowDrawable(s, p, c.style.value));
        break;
      case ToolKind.line:
        setState(() => _preview = LineDrawable(s, p, c.style.value));
        break;
      case ToolKind.highlighter:
        setState(() => _preview = HighlighterDrawable(s, p, c.style.value));
        break;
      case ToolKind.pen:
        _penPoints = [...?_penPoints, p];
        setState(() => _preview = PenDrawable(_penPoints!, c.style.value));
        break;
      case ToolKind.blur:
        setState(() {
          _cursor = p; // keep the crosshair/loupe on the dragging corner
          _preview = BlurDrawable(Rect.fromPoints(s, p), c.style.value);
        });
        break;
      case ToolKind.pixelate:
        setState(() {
          _cursor = p;
          _preview = PixelateDrawable(Rect.fromPoints(s, p), c.style.value);
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
    if (_resizeCorner != null && orig is RectShaped) {
      final shape = orig as RectShaped;
      final corners = _rectCorners(shape.rect);
      final opposite = corners[(_resizeCorner! + 2) % 4];
      setState(
        () => _editPreview = shape.resizedTo(Rect.fromPoints(opposite, p)),
      );
    } else {
      final start = _moveStart;
      if (start != null) {
        setState(() => _editPreview = orig.moved(p - start));
      }
    }
  }

  void _panEnd(DragEndDetails d) {
    _bridge.setDrawingLock(
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
      final r = _crop.rect.value;
      if (r != null && r.width >= 2 && r.height >= 2) {
        widget.onExport(r); // drag-release commits the crop
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
    if (_editingText && _textPos != null && _richCtl != null) {
      final live = TextDrawable(_textPos!, _richCtl!.toRuns(), c.style.value);
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
        (_toolbarPos.dx + delta.dx).clamp(0.0, widget.display.width - 80),
        (_toolbarPos.dy + delta.dy).clamp(0.0, widget.display.height - 60),
      );
    });
  }

  Offset _loupeOrigin() {
    const size = 120.0;
    const gap = 24.0;
    var lx = _cursor.dx + gap;
    var ly = _cursor.dy + gap;
    if (lx + size > widget.display.width) lx = _cursor.dx - gap - size;
    if (ly + size > widget.display.height) ly = _cursor.dy - gap - size;
    return Offset(
      lx.clamp(0.0, widget.display.width - size),
      ly.clamp(0.0, widget.display.height - size),
    );
  }

  @override
  Widget build(BuildContext context) {
    _syncCursorHidden(); // reconcile system-cursor visibility (pushed on change)
    final inCrop = _inCrop;
    final showsCrosshair = _showsCrosshair;
    final loupeOrigin = _loupeOrigin();
    // Window-snap target: the hovered window, or — Crop only — the whole display
    // over bare desktop; null when no snap tool is active or while dragging.
    final snapTarget =
        (_active && _snapTools.contains(c.tool.value) && !_dragging)
        ? (_hoverWindow ??
              (c.tool.value == ToolKind.crop ? _fullDisplayRect : null))
        : null;
    // Outermost listener tracks the cursor for the crosshair from the RAW
    // pointer stream — fires everywhere (incl. over the toolbar, and after a
    // right-click ends the pan), so the crosshair follows continuously on the
    // active display. WHICH display is active is decided by the native cursor
    // poll (_onActiveSignal), not by enter/exit here.
    return Listener(
      onPointerHover: _trackCursor,
      onPointerMove: _trackCursor,
      child: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Layer 1: frozen image (full color, no dim in the annotate phase).
            RepaintBoundary(
              child: Image.memory(
                widget.display.pngBytes,
                fit: BoxFit.fill,
                gaplessPlayback: true,
              ),
            ),
            // Layer 2: annotation layer (+ a highlight box on the hovered/selected
            // drawable in the annotate phase).
            RepaintBoundary(
              child: CustomPaint(
                painter: DrawablePainter(
                  // Annotations always paint (so an inactive display still shows
                  // its drawings); only the selection highlight is gated on focus.
                  drawables: _effectiveDrawables(),
                  selectedIndex: (!_active || inCrop || _editingText)
                      ? null
                      : c.selectedIndex.value,
                  blurredFull: _blurredFull,
                  pixelatedFull: _pixelatedFull,
                ),
                size: Size.infinite,
              ),
            ),
            // Our own text-selection highlight — shown when the inline field is
            // blurred (e.g. while typing a pt value), so the selected range stays
            // visible. When the field is focused it draws its own highlight.
            if (_active &&
                _editingText &&
                _richCtl != null &&
                _textPos != null &&
                !_textFocus.hasFocus &&
                !_richCtl!.selection.isCollapsed)
              IgnorePointer(
                child: CustomPaint(
                  size: Size.infinite,
                  painter: TextSelectionPainter(
                    span: buildTextSpan(
                      TextDrawable(
                        _textPos!,
                        _richCtl!.toRuns(),
                        c.style.value,
                      ),
                    ),
                    origin: _textPos!,
                    selection: _richCtl!.selection,
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
                        Positioned(
                          left: rect.left,
                          top: (rect.bottom + 4).clamp(
                            0,
                            widget.display.height,
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
                        size: Size.infinite,
                        painter: rect == null
                            ? null
                            : WindowHighlightPainter(rect),
                      ),
                    ),
                  ),
            // Precision HUD: full-screen crosshair + pixel loupe — crop and the
            // raster region tools (blur/pixelate), active display only.
            if (_active && showsCrosshair)
              IgnorePointer(
                child: CustomPaint(
                  size: Size.infinite,
                  painter: CrosshairPainter(_cursor),
                ),
              ),
            // Loupe is bound to the crosshair — shown/hidden together, so it
            // never flickers off when hovering over an existing region.
            if (_active && showsCrosshair)
              Positioned(
                left: loupeOrigin.dx,
                top: loupeOrigin.dy,
                child: IgnorePointer(
                  child: CustomPaint(
                    size: const Size(120, 120),
                    painter: LoupePainter(
                      image: widget.frozenImage,
                      cursorLogical: _cursor,
                      scaleFactor: widget.display.scaleFactor,
                      drawables: _effectiveDrawables(),
                      blurredFull: _blurredFull,
                      pixelatedFull: _pixelatedFull,
                      logicalSize: Size(
                        widget.display.width,
                        widget.display.height,
                      ),
                    ),
                  ),
                ),
              ),
            // Small reticle for the drawing tools (replaces the system arrow with
            // a precise inverting cross). Region tools use the crosshair above.
            if (_showsReticle)
              IgnorePointer(
                child: CustomPaint(
                  size: Size.infinite,
                  painter: ReticlePainter(_cursor),
                ),
              ),
            // Gesture + hover layer. A Listener catches the right button reliably
            // even mid-drag (GestureDetector's secondary-tap loses the arena to an
            // active pan), so right-click can cancel an in-progress crop/draw.
            Positioned.fill(
              // Stable key so this layer (and its pan recognizer) is matched by
              // key and never re-created when sibling layers above (the animated
              // snap highlight) or below (the toolbar) toggle or change type
              // mid-drag. Without it the unkeyed Stack diff misaligns and tears
              // down the pan mid-gesture (crop stuck at 0x0).
              key: const ValueKey('editor-gesture-layer'),
              child: Listener(
                // Watch down/move/up: a right-button press DURING a left drag
                // arrives as a move (the pointer is already down), not a down — so
                // the old onPointerDown-only check never saw it and the crop
                // committed. The latch fires _onRightDown once per right press.
                onPointerDown: _onPointerButtons,
                onPointerMove: _onPointerButtons,
                onPointerUp: _onPointerButtons,
                child: MouseRegion(
                  // Over the canvas we always draw our OWN cursor (full crosshair
                  // for region tools, small reticle for drawing tools), so hide
                  // the system cursor — except while editing text. Over the
                  // toolbar this region isn't hit, so its normal click cursor
                  // shows.
                  cursor: (_active && !_editingText)
                      ? SystemMouseCursors.none
                      : SystemMouseCursors.basic,
                  onEnter: (_) => setState(() => _overCanvas = true),
                  onExit: (_) => setState(() => _overCanvas = false),
                  onHover: _onHover,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: _onTapUp,
                    onPanStart: _panStart,
                    onPanUpdate: _panUpdate,
                    onPanEnd: _panEnd,
                    // Safety net: if the pan is cancelled (never reaches
                    // onPanEnd), still release the cursor confine + transient
                    // state so the cursor is never stranded on one display.
                    onPanCancel: () {
                      _bridge.setDrawingLock(false);
                      _cancelGesture = false;
                      setState(() {
                        _resetDrawState();
                        _resetEditState();
                        _cropping = false;
                      });
                    },
                  ),
                ),
              ),
            ),
            // Inline multiline text editor (Enter commits, Shift+Enter newline).
            if (_active && _editingText && _textPos != null && _richCtl != null)
              Positioned(
                left: _textPos!.dx,
                top: _textPos!.dy,
                child: Material(
                  type: MaterialType.transparency,
                  child: Focus(
                    onKeyEvent: _onTextKey,
                    child: IntrinsicWidth(
                      child: TextField(
                        controller: _richCtl,
                        focusNode: _textFocus,
                        autofocus: true,
                        maxLines: null,
                        // Don't auto-unfocus when tapping the toolbar: that's how
                        // style controls adjust the selected text WHILE editing.
                        // Canvas taps still commit explicitly (_onTapUp/_panStart);
                        // switching tools commits via focus loss.
                        onTapOutside: (_) {},
                        cursorColor: c.style.value.color,
                        // The controller renders transparent per-run spans (the
                        // painter draws the visible rich text). Disable strut so
                        // line metrics follow the (mixed-size) glyphs like the
                        // painter does.
                        style: textStyleOf(c.style.value),
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
            // selection / screen isn't obscured.
            if (_active && !_cropping)
              Positioned(
                left: _toolbarPos.dx,
                top: _toolbarPos.dy,
                // Material ancestor for the toolbar's TextField (pt) + IconButtons.
                child: Material(
                  type: MaterialType.transparency,
                  child: EditorToolbar(
                    controller: c,
                    onMove: _moveToolbar,
                    onPtEditingDone: () {
                      if (_editingText) _textFocus.requestFocus();
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
