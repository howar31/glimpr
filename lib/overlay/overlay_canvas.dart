import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../capture/captured_display.dart';
import 'selection_controller.dart';
import 'selection_label.dart';
import 'selection_scrim.dart';

/// Full-bleed frozen image for ONE display, with a marquee + dim-outside scrim.
/// Reports the selection (overlay-local logical coords) via [onCommit] on
/// drag-release, or [onCancel] on Esc. The window is sized to the display's
/// logical frame, so local coords == display-local logical coords (no fit
/// factor — see Phase-1 lesson: that derivation is deleted here).
class OverlayCanvas extends StatefulWidget {
  final CapturedDisplay display;
  final ValueChanged<Rect> onCommit;
  final VoidCallback onCancel;
  const OverlayCanvas({
    super.key,
    required this.display,
    required this.onCommit,
    required this.onCancel,
  });

  @override
  State<OverlayCanvas> createState() => _OverlayCanvasState();
}

class _OverlayCanvasState extends State<OverlayCanvas> {
  final _selection = SelectionController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _selection.dispose();
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
      _selection.clear();
      widget.onCancel();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (d) => _selection.begin(d.localPosition),
        onPanUpdate: (d) => _selection.update(d.localPosition),
        onPanEnd: (_) {
          final r = _selection.rect.value;
          if (r != null && r.width >= 2 && r.height >= 2) {
            widget.onCommit(r);
          }
          // Sub-threshold drag = single-click snap (whole display in Phase 2).
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Frozen image, never repaints during drag.
            RepaintBoundary(
              child: Image.memory(
                widget.display.pngBytes,
                fit: BoxFit.fill,
                gaplessPlayback: true,
              ),
            ),
            // Scrim + border + label repaint per drag tick via the notifier.
            RepaintBoundary(
              child: ValueListenableBuilder<Rect?>(
                valueListenable: _selection.rect,
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
                            color: Colors.white, fontSize: 12,
                            backgroundColor: Color(0xAA000000),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
