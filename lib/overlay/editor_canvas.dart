import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../capture/captured_display.dart';
import '../editor/drawable.dart';
import '../editor/drawable_painter.dart';
import '../editor/editor_controller.dart';
import '../editor/hit_test.dart';
import 'selection_controller.dart';
import 'selection_label.dart';
import 'selection_scrim.dart';
import 'toolbar.dart';

/// In-overlay annotation editor for ONE display. Layers: (1) frozen image,
/// (2) annotation layer, (3) crop scrim (crop phase only). Flow B: annotate with
/// NO dim, then the Crop tool drag-commits an export; Return exports the whole
/// display. Local gesture coords == display-local logical coords (window is
/// sized to the display's logical frame, image is fit: fill).
class EditorCanvas extends StatefulWidget {
  final CapturedDisplay display;
  final EditorController controller;
  final Future<void> Function(Rect? selectionLogical) onExport;
  final VoidCallback onCancel;
  const EditorCanvas({
    super.key,
    required this.display,
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

  // In-progress shape/arrow preview (annotate phase).
  Drawable? _preview;
  Offset? _dragStart;

  // Select-tool edit (move or rectangle-corner resize) preview.
  int? _editIndex;
  Drawable? _editOriginal;
  Drawable? _editPreview;
  Offset? _moveStart;
  int? _resizeCorner; // 0=TL 1=TR 2=BR 3=BL on a RectangleDrawable, else null

  // Crop drag state (for arrow-key nudge while the mouse is held).
  bool _cropping = false;
  Offset _cropPointer = Offset.zero;

  // Inline text editing.
  final _textCtl = TextEditingController();
  final _textFocus = FocusNode();
  Offset? _textPos;
  bool _editingText = false;

  EditorController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.document.addListener(_rebuild);
    c.selectedIndex.addListener(_rebuild);
    c.tool.addListener(_rebuild);
    c.phase.addListener(_rebuild);
    _textFocus.addListener(_onTextFocusChange);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    c.document.removeListener(_rebuild);
    c.selectedIndex.removeListener(_rebuild);
    c.tool.removeListener(_rebuild);
    c.phase.removeListener(_rebuild);
    _textFocus.removeListener(_onTextFocusChange);
    _focus.dispose();
    _crop.dispose();
    _textCtl.dispose();
    _textFocus.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _onTextFocusChange() {
    // Clicking away from the text field commits it.
    if (_editingText && !_textFocus.hasFocus) _commitText();
  }

  // ---- keyboard ----------------------------------------------------------

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final key = e.logicalKey;
    final meta = HardwareKeyboard.instance.isMetaPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;

    if (key == LogicalKeyboardKey.escape) {
      if (_editingText) {
        _cancelText();
        return KeyEventResult.handled;
      }
      if (c.phase.value == EditorPhase.crop) {
        _crop.clear();
        _cropping = false;
        c.selectTool(ToolKind.select); // crop -> back to annotate
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

    if ((key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter) &&
        c.phase.value == EditorPhase.annotate &&
        !_editingText) {
      widget.onExport(null); // no crop -> whole display
      return KeyEventResult.handled;
    }

    if ((key == LogicalKeyboardKey.delete ||
            key == LogicalKeyboardKey.backspace) &&
        c.tool.value == ToolKind.select &&
        c.selectedIndex.value != null &&
        !_editingText) {
      c.deleteSelected();
      return KeyEventResult.handled;
    }

    // Arrow-nudge the crop pointer by 1px while the mouse is held.
    if (_cropping) {
      Offset? delta;
      if (key == LogicalKeyboardKey.arrowLeft) delta = const Offset(-1, 0);
      if (key == LogicalKeyboardKey.arrowRight) delta = const Offset(1, 0);
      if (key == LogicalKeyboardKey.arrowUp) delta = const Offset(0, -1);
      if (key == LogicalKeyboardKey.arrowDown) delta = const Offset(0, 1);
      if (delta != null) {
        _cropPointer += delta;
        _crop.update(_cropPointer);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  // ---- text editing ------------------------------------------------------

  void _startText(Offset at) {
    setState(() {
      _textPos = at;
      _editingText = true;
      _textCtl.text = '';
    });
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _textFocus.requestFocus());
  }

  void _commitText() {
    final pos = _textPos;
    final text = _textCtl.text;
    if (pos != null && text.trim().isNotEmpty) {
      c.commitDrawable(TextDrawable(pos, text, c.style.value));
    }
    _cancelText();
  }

  void _cancelText() {
    setState(() {
      _editingText = false;
      _textPos = null;
      _textCtl.clear();
    });
    _focus.requestFocus();
  }

  // ---- pointer gestures --------------------------------------------------

  List<Offset> _rectCorners(Rect r) =>
      [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft];

  void _onTapUp(TapUpDetails d) {
    if (_editingText) {
      _commitText();
      return;
    }
    final p = d.localPosition;
    switch (c.tool.value) {
      case ToolKind.text:
        _startText(p);
        break;
      case ToolKind.select:
        c.selectedIndex.value = hitTestTop(c.document.value.drawables, p);
        break;
      default:
        break;
    }
  }

  void _panStart(DragStartDetails d) {
    final p = d.localPosition;
    switch (c.tool.value) {
      case ToolKind.rectangle:
      case ToolKind.arrow:
        _dragStart = p;
        _preview = null;
        break;
      case ToolKind.crop:
        _cropping = true;
        _cropPointer = p;
        _crop.begin(p);
        break;
      case ToolKind.select:
        _beginSelectDrag(p);
        break;
      case ToolKind.text:
        break;
    }
  }

  void _beginSelectDrag(Offset p) {
    final drawables = c.document.value.drawables;
    final selIdx = c.selectedIndex.value;
    // Rectangle corner resize when the press lands on a handle of the selection.
    if (selIdx != null && selIdx < drawables.length) {
      final sel = drawables[selIdx];
      if (sel is RectangleDrawable) {
        final corners = _rectCorners(sel.rect.inflate(4));
        for (var i = 0; i < corners.length; i++) {
          if ((corners[i] - p).distance <= 12) {
            _editIndex = selIdx;
            _editOriginal = sel;
            _editPreview = sel;
            _resizeCorner = i;
            return;
          }
        }
      }
    }
    // Otherwise hit-test to select + move.
    final i = hitTestTop(drawables, p);
    c.selectedIndex.value = i;
    if (i != null) {
      _editIndex = i;
      _editOriginal = drawables[i];
      _editPreview = drawables[i];
      _moveStart = p;
      _resizeCorner = null;
    }
  }

  void _panUpdate(DragUpdateDetails d) {
    final p = d.localPosition;
    switch (c.tool.value) {
      case ToolKind.rectangle:
        final s = _dragStart;
        if (s != null) {
          setState(() =>
              _preview = RectangleDrawable(Rect.fromPoints(s, p), c.style.value));
        }
        break;
      case ToolKind.arrow:
        final s = _dragStart;
        if (s != null) {
          setState(() => _preview = ArrowDrawable(s, p, c.style.value));
        }
        break;
      case ToolKind.crop:
        _cropPointer = p;
        _crop.update(p);
        break;
      case ToolKind.select:
        _updateSelectDrag(p);
        break;
      case ToolKind.text:
        break;
    }
  }

  void _updateSelectDrag(Offset p) {
    final orig = _editOriginal;
    if (orig == null) return;
    if (_resizeCorner != null && orig is RectangleDrawable) {
      // Opposite corner stays fixed; dragged corner follows the pointer.
      final corners = _rectCorners(orig.rect);
      final opposite = corners[(_resizeCorner! + 2) % 4];
      setState(() =>
          _editPreview = orig.resized(Rect.fromPoints(opposite, p)));
    } else {
      final start = _moveStart;
      if (start != null) {
        setState(() => _editPreview = orig.moved(p - start));
      }
    }
  }

  void _panEnd(DragEndDetails d) {
    switch (c.tool.value) {
      case ToolKind.rectangle:
      case ToolKind.arrow:
        final prev = _preview;
        if (prev != null && prev.bounds.longestSide >= 3) {
          c.commitDrawable(prev);
        }
        setState(() {
          _preview = null;
          _dragStart = null;
        });
        break;
      case ToolKind.crop:
        _cropping = false;
        final r = _crop.rect.value;
        if (r != null && r.width >= 2 && r.height >= 2) {
          widget.onExport(r); // drag-release commits the crop
        } else {
          _crop.clear();
        }
        break;
      case ToolKind.select:
        final i = _editIndex;
        final prev = _editPreview;
        if (i != null && prev != null) {
          c.document.value = c.document.value.replaceAt(i, prev);
        }
        _editIndex = null;
        _editOriginal = null;
        _editPreview = null;
        _moveStart = null;
        _resizeCorner = null;
        break;
      case ToolKind.text:
        break;
    }
  }

  // ---- build -------------------------------------------------------------

  List<Drawable> _effectiveDrawables() {
    final list = [...c.document.value.drawables];
    final i = _editIndex;
    final prev = _editPreview;
    if (i != null && prev != null && i < list.length) list[i] = prev;
    if (_preview != null) list.add(_preview!);
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final inCrop = c.phase.value == EditorPhase.crop;
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
          // Layer 2: annotation layer.
          RepaintBoundary(
            child: CustomPaint(
              painter: DrawablePainter(
                drawables: _effectiveDrawables(),
                selectedIndex:
                    c.tool.value == ToolKind.select ? c.selectedIndex.value : null,
              ),
              size: Size.infinite,
            ),
          ),
          // Layer 3: crop scrim — only in the crop phase.
          if (inCrop)
            RepaintBoundary(
              child: ValueListenableBuilder<Rect?>(
                valueListenable: _crop.rect,
                builder: (context, rect, _) => Stack(
                  fit: StackFit.expand,
                  children: [
                    CustomPaint(painter: SelectionScrimPainter(selection: rect)),
                    if (rect != null)
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
                ),
              ),
            ),
          // Gesture layer (transparent, full-canvas).
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: _onTapUp,
              onPanStart: _panStart,
              onPanUpdate: _panUpdate,
              onPanEnd: _panEnd,
            ),
          ),
          // Inline text editor.
          if (_editingText && _textPos != null)
            Positioned(
              left: _textPos!.dx,
              top: _textPos!.dy,
              child: IntrinsicWidth(
                child: TextField(
                  controller: _textCtl,
                  focusNode: _textFocus,
                  autofocus: true,
                  cursorColor: c.style.value.color,
                  style: TextStyle(
                    color: c.style.value.color,
                    fontSize: c.style.value.fontSize,
                  ),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                  ),
                  onSubmitted: (_) => _commitText(),
                ),
              ),
            ),
          // Toolbar (bottom-center).
          Positioned(
            left: 0,
            right: 0,
            bottom: 28,
            child: Center(child: EditorToolbar(controller: c)),
          ),
        ],
      ),
    );
  }
}
