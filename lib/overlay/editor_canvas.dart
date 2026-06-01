import 'dart:ui' as ui;
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

/// Blur radius (logical px) and pixelate block size (native px) for the raster
/// region tools. Fixed in Phase 3; a strength control is deferred to settings.
const double _kBlurSigma = 12;
const double _kPixelCell = 12;

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
  const EditorCanvas({
    super.key,
    required this.display,
    required this.frozenImage,
    required this.controller,
    required this.onExport,
    required this.onCancel,
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

  // New-shape preview (drag on empty).
  Drawable? _preview;
  Offset? _dragStart;
  List<Offset>? _penPoints; // accumulated freehand points (pen tool)

  // Move/resize an existing drawable.
  int? _editIndex;
  Drawable? _editOriginal;
  Drawable? _editPreview;
  Offset? _moveStart;
  int? _resizeCorner; // 0=TL 1=TR 2=BR 3=BL on a RectangleDrawable

  bool _cropping = false;
  bool _cancelGesture = false; // right-click cancelled the active drag

  // Inline rich-text editing.
  final _textFocus = FocusNode();
  RichTextController? _richCtl;
  Offset? _textPos;
  int? _editTextIndex; // re-editing an existing text drawable
  bool _editingText = false;

  EditorController get c => widget.controller;
  bool get _inCrop => c.phase.value == EditorPhase.crop;

  @override
  void initState() {
    super.initState();
    _cursor = Offset(widget.display.width / 2, widget.display.height / 2);
    _toolbarPos =
        Offset(widget.display.width / 2 - 160, widget.display.height - 120);
    c.document.addListener(_rebuild);
    c.selectedIndex.addListener(_rebuild);
    c.tool.addListener(_rebuild);
    c.tool.addListener(_onToolChanged);
    c.phase.addListener(_rebuild);
    c.style.addListener(_onStyleChanged);
    _textFocus.addListener(_rebuild); // repaint our selection on focus changes
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
    // Selecting the Paste tool pastes the clipboard image immediately (the
    // guard stops the selectTool inside _pasteImage from re-triggering this).
    if (c.tool.value == ToolKind.paste && !_pasting) _pasteImage();
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
    if (_editingText) return KeyEventResult.ignored; // text wrapper handles keys
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

    // Tool shortcuts 1-9 (must mirror EditorToolbar.tools order):
    // 1=Crop 2=Rectangle 3=Arrow 4=Text 5=Ellipse 6=Line 7=Pen 8=Highlighter
    // 9=Step. Raster tools (blur/pixelate/paste) have no digit shortcut.
    const order = [
      ToolKind.crop,
      ToolKind.rectangle,
      ToolKind.arrow,
      ToolKind.text,
      ToolKind.ellipse,
      ToolKind.line,
      ToolKind.pen,
      ToolKind.highlighter,
      ToolKind.step,
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

    // Crop arrow-nudge: move crosshair/selection AND warp the OS cursor 1px so a
    // subsequent physical mouse move continues from the nudged point.
    if (_inCrop) {
      Offset? delta;
      if (key == LogicalKeyboardKey.arrowLeft) delta = const Offset(-1, 0);
      if (key == LogicalKeyboardKey.arrowRight) delta = const Offset(1, 0);
      if (key == LogicalKeyboardKey.arrowUp) delta = const Offset(0, -1);
      if (key == LogicalKeyboardKey.arrowDown) delta = const Offset(0, 1);
      if (delta != null) {
        final next = Offset(
          (_cursor.dx + delta.dx).clamp(0.0, widget.display.width),
          (_cursor.dy + delta.dy).clamp(0.0, widget.display.height),
        );
        setState(() => _cursor = next);
        if (_cropping) _crop.update(next);
        _bridge.warpCursor(
            widget.display.left + next.dx, widget.display.top + next.dy);
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
        color: c.style.value.color, size: c.style.value.fontSize)
      ..addListener(_rebuild);
    setState(() {
      _richCtl = ctl;
      _editTextIndex = null;
      _textPos = at;
      _editingText = true;
      c.selectedIndex.value = null;
    });
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _textFocus.requestFocus());
  }

  void _reEditText(int idx) {
    final d = c.document.value.drawables[idx];
    if (d is! TextDrawable) return;
    final ctl = RichTextController.fromRuns(d.runs,
        color: c.style.value.color, size: c.style.value.fontSize)
      ..addListener(_rebuild);
    setState(() {
      _richCtl = ctl;
      _editTextIndex = idx;
      _textPos = d.position;
      _editingText = true;
      c.selectedIndex.value = null;
    });
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _textFocus.requestFocus());
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

  List<Offset> _rectCorners(Rect r) =>
      [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft];

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
    if (cur != null && cur < drawables.length && _nearHandles(drawables[cur], p)) {
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
    switch (c.tool.value) {
      case ToolKind.text:
        final idx = _hitActiveType(p);
        idx != null ? _reEditText(idx) : _startText(p);
        break;
      case ToolKind.step:
        // Tap on empty space places a new auto-numbered badge; tap on an
        // existing badge just selects it (drag the body to move).
        final idx = _hitActiveType(p);
        if (idx == null) {
          c.commitDrawable(StepDrawable(
              p, nextStepNumber(c.document.value.drawables), c.style.value));
        } else {
          c.selectedIndex.value = idx;
        }
        break;
      case ToolKind.rectangle:
      case ToolKind.ellipse:
      case ToolKind.arrow:
      case ToolKind.line:
      case ToolKind.pen:
      case ToolKind.highlighter:
      case ToolKind.blur:
      case ToolKind.pixelate:
      case ToolKind.paste:
        c.selectedIndex.value = _hitActiveType(p);
        break;
      case ToolKind.crop:
        break;
    }
  }

  void _onRightDown(Offset p) {
    // Crop: right-click cancels the selection (set _cancelGesture so the
    // pending pan-end does NOT commit/export).
    if (c.tool.value == ToolKind.crop) {
      setState(() {
        _crop.clear();
        _cropping = false;
        _cancelGesture = true;
      });
      return;
    }
    // Cancel an in-progress draw / move / resize.
    if (_preview != null || _dragStart != null || _editIndex != null) {
      setState(() {
        _cancelGesture = true;
        _resetDrawState();
        _resetEditState();
      });
      return;
    }
    // Otherwise delete the same-type drawable under the cursor.
    final idx = _hitActiveType(p);
    if (idx != null) {
      c.document.value = c.document.value.removeAt(idx);
      c.selectedIndex.value = null;
    }
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
    final p = d.localPosition;
    if (c.tool.value == ToolKind.crop) {
      _cropping = true;
      setState(() => _cursor = p);
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
    if (_cancelGesture) return;
    final p = d.localPosition;
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
        setState(() =>
            _preview = RectangleDrawable(Rect.fromPoints(s, p), c.style.value));
        break;
      case ToolKind.ellipse:
        setState(() =>
            _preview = EllipseDrawable(Rect.fromPoints(s, p), c.style.value));
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
        setState(() =>
            _preview = BlurDrawable(Rect.fromPoints(s, p), _kBlurSigma, c.style.value));
        break;
      case ToolKind.pixelate:
        setState(() => _preview = PixelateDrawable(
            Rect.fromPoints(s, p), _kPixelCell, null, c.style.value));
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
          () => _editPreview = shape.resizedTo(Rect.fromPoints(opposite, p)));
    } else {
      final start = _moveStart;
      if (start != null) {
        setState(() => _editPreview = orig.moved(p - start));
      }
    }
  }

  void _panEnd(DragEndDetails d) {
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
      if (prev != null) {
        // Replace now (one undo step = the move/resize). A moved/resized
        // pixelate keeps its old mosaic (still obscured) until the fresh one
        // is computed, so the region is never exposed.
        c.document.value = c.document.value.replaceAt(i, prev);
        if (prev is PixelateDrawable) _fillMosaicAt(i);
      }
      return;
    }
    final prev = _preview;
    setState(_resetDrawState);
    if (prev != null && prev.bounds.longestSide >= 3) {
      // Commit immediately. A new pixelate has a null mosaic and renders as a
      // live blur (already obscured) until its mosaic is backfilled.
      c.commitDrawable(prev);
      if (prev is PixelateDrawable) {
        _fillMosaicAt(c.document.value.drawables.length - 1);
      }
    }
  }

  /// Compute the pixelate mosaic for the region at [i] and silently backfill it
  /// (no extra undo step). Guards against the drawable changing meanwhile, so a
  /// stale async result is dropped after an undo/edit.
  Future<void> _fillMosaicAt(int i) async {
    final list = c.document.value.drawables;
    if (i < 0 || i >= list.length) return;
    final d = list[i];
    if (d is! PixelateDrawable || d.rect.width < 1 || d.rect.height < 1) return;
    final m = await pixelateRegion(
        widget.frozenImage, d.rect, widget.display.scaleFactor, d.cell);
    if (!mounted) return;
    final cur = c.document.value.drawables;
    if (i < cur.length && identical(cur[i], d)) {
      c.document.value = c.document.value.replaceAtSilent(i, d.withMosaic(m));
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
    final inCrop = _inCrop;
    final loupeOrigin = _loupeOrigin();
    return Focus(
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
                drawables: _effectiveDrawables(),
                selectedIndex:
                    (inCrop || _editingText) ? null : c.selectedIndex.value,
                frozenImage: widget.frozenImage,
                scaleFactor: widget.display.scaleFactor,
              ),
              size: Size.infinite,
            ),
          ),
          // Our own text-selection highlight — shown when the inline field is
          // blurred (e.g. while typing a pt value), so the selected range stays
          // visible. When the field is focused it draws its own highlight.
          if (_editingText &&
              _richCtl != null &&
              _textPos != null &&
              !_textFocus.hasFocus &&
              !_richCtl!.selection.isCollapsed)
            IgnorePointer(
              child: CustomPaint(
                size: Size.infinite,
                painter: TextSelectionPainter(
                  span: buildTextSpan(
                      TextDrawable(_textPos!, _richCtl!.toRuns(), c.style.value)),
                  origin: _textPos!,
                  selection: _richCtl!.selection,
                ),
              ),
            ),
          // Layer 3: crop scrim — only once a selection drag exists.
          if (inCrop)
            RepaintBoundary(
              child: ValueListenableBuilder<Rect?>(
                valueListenable: _crop.rect,
                builder: (context, rect, _) {
                  if (rect == null) return const SizedBox.shrink();
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      CustomPaint(
                          painter: SelectionScrimPainter(selection: rect)),
                      Positioned(
                        left: rect.left,
                        top: (rect.bottom + 4).clamp(0, widget.display.height),
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
          // Crop HUD: full-screen crosshair + pixel loupe.
          if (inCrop)
            IgnorePointer(
              child: CustomPaint(
                size: Size.infinite,
                painter: CrosshairPainter(_cursor),
              ),
            ),
          if (inCrop)
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
                  ),
                ),
              ),
            ),
          // Gesture + hover layer. A Listener catches the right button reliably
          // even mid-drag (GestureDetector's secondary-tap loses the arena to an
          // active pan), so right-click can cancel an in-progress crop/draw.
          Positioned.fill(
            child: Listener(
              onPointerDown: (e) {
                if (e.buttons == kSecondaryButton) _onRightDown(e.localPosition);
              },
              child: MouseRegion(
                cursor: inCrop
                    ? SystemMouseCursors.none // our crosshair replaces it
                    : SystemMouseCursors.basic,
                onHover: _onHover,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: _onTapUp,
                  onPanStart: _panStart,
                  onPanUpdate: _panUpdate,
                  onPanEnd: _panEnd,
                ),
              ),
            ),
          ),
          // Inline multiline text editor (Enter commits, Shift+Enter newline).
          if (_editingText && _textPos != null && _richCtl != null)
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
          // Draggable toolbar.
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
    );
  }
}
