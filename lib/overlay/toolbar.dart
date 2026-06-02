import 'package:flutter/material.dart';
import '../editor/draw_style.dart';
import '../editor/editor_controller.dart';

/// Draggable bottom toolbar: a contextual options row above a main tool row.
/// Each tool shows a number badge (its 1-based keyboard shortcut). [onMove] is
/// fed pointer deltas from the drag handle so the host can reposition it.
class EditorToolbar extends StatelessWidget {
  final EditorController controller;
  final void Function(Offset delta) onMove;
  final VoidCallback onPtEditingDone; // re-focus the text after pt entry
  const EditorToolbar({
    super.key,
    required this.controller,
    required this.onMove,
    required this.onPtEditingDone,
  });

  // (kind, icon, shortcut badge). Order mirrors editor_canvas `_onKey`:
  // 1=Crop 2=Rectangle 3=Ellipse 4=Line 5=Arrow 6=Pen 7=Text 8=Highlighter
  // 9=Step, then B=Blur P=Pixelate (letter shortcuts); Paste has none.
  static const tools = <(ToolKind, IconData, String?)>[
    (ToolKind.crop, Icons.crop, '1'),
    (ToolKind.rectangle, Icons.crop_square, '2'),
    (ToolKind.ellipse, Icons.circle_outlined, '3'),
    (ToolKind.line, Icons.horizontal_rule, '4'),
    (ToolKind.arrow, Icons.north_east, '5'),
    (ToolKind.pen, Icons.gesture, '6'),
    (ToolKind.text, Icons.title, '7'),
    (ToolKind.highlighter, Icons.border_color, '8'),
    (ToolKind.step, Icons.looks_one, '9'),
    (ToolKind.blur, Icons.blur_on, 'B'),
    (ToolKind.pixelate, Icons.grid_on, 'P'),
    (ToolKind.paste, Icons.content_paste, null),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _OptionsRow(controller: controller, onPtEditingDone: onPtEditingDone),
        const SizedBox(height: 6),
        _Bar(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag handle — move the whole toolbar out of the way.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanUpdate: (d) => onMove(d.delta),
                child: const MouseRegion(
                  cursor: SystemMouseCursors.move,
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 2),
                    child: Icon(
                      Icons.drag_indicator,
                      color: Colors.white54,
                      size: 20,
                    ),
                  ),
                ),
              ),
              for (final t in tools)
                _ToolButton(
                  controller: controller,
                  kind: t.$1,
                  icon: t.$2,
                  shortcut: t.$3,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A tool icon with a bottom-right shortcut-number badge.
class _ToolButton extends StatelessWidget {
  final EditorController controller;
  final ToolKind kind;
  final IconData icon;
  final String? shortcut; // badge label (digit or letter); null = no shortcut
  const _ToolButton({
    required this.controller,
    required this.kind,
    required this.icon,
    required this.shortcut,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ToolKind>(
      valueListenable: controller.tool,
      builder: (_, active, _) {
        final on = active == kind;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            IconButton(
              icon: Icon(icon),
              color: on ? Colors.lightBlueAccent : Colors.white,
              onPressed: () => controller.selectTool(kind),
            ),
            if (shortcut != null)
              Positioned(
                right: 2,
                bottom: 2,
                child: Text(
                  shortcut!,
                  style: TextStyle(
                    fontSize: 9,
                    height: 1,
                    color: on ? Colors.lightBlueAccent : Colors.white54,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _Bar extends StatelessWidget {
  final Widget child;
  const _Bar({required this.child});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: const Color(0xEE2B2B2B),
      borderRadius: BorderRadius.circular(10),
    ),
    child: child,
  );
}

/// Per-tool options: color (all drawing tools), stroke width (rect/arrow only),
/// font size (text only). Hidden for the Crop tool.
class _OptionsRow extends StatelessWidget {
  final EditorController controller;
  final VoidCallback onPtEditingDone;
  const _OptionsRow({required this.controller, required this.onPtEditingDone});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ToolKind>(
      valueListenable: controller.tool,
      builder: (_, tool, _) {
        // Tools that carry a color (all vector draw tools; not crop/raster).
        const colorTools = {
          ToolKind.rectangle,
          ToolKind.ellipse,
          ToolKind.arrow,
          ToolKind.line,
          ToolKind.pen,
          ToolKind.highlighter,
          ToolKind.text,
          ToolKind.step,
        };
        if (!colorTools.contains(tool)) return const SizedBox.shrink();
        // Stroke-width applies to the shape/stroke tools (not text/step).
        const widthTools = {
          ToolKind.rectangle,
          ToolKind.ellipse,
          ToolKind.arrow,
          ToolKind.line,
          ToolKind.pen,
          ToolKind.highlighter,
        };
        final showsWidth = widthTools.contains(tool);
        // Font size = glyph size for text, badge radius for the numbered step.
        final showsFont = tool == ToolKind.text || tool == ToolKind.step;
        return _Bar(
          child: ValueListenableBuilder<DrawStyle>(
            valueListenable: controller.style,
            builder: (_, style, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final c in kColorPresets)
                  _ColorSwatch(controller, style, c),
                if (showsWidth) ...[
                  const SizedBox(width: 10),
                  for (final w in kStrokeWidths)
                    _WidthSwatch(controller, style, w),
                ],
                if (showsFont) ...[
                  const SizedBox(width: 10),
                  _FontControl(controller, onPtEditingDone),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ColorSwatch extends StatelessWidget {
  final EditorController controller;
  final DrawStyle style;
  final Color color;
  const _ColorSwatch(this.controller, this.style, this.color);
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => controller.setColor(color),
    child: Container(
      width: 18,
      height: 18,
      margin: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(
          color: style.color == color ? Colors.white : Colors.black26,
          width: style.color == color ? 2 : 1,
        ),
      ),
    ),
  );
}

class _WidthSwatch extends StatelessWidget {
  final EditorController controller;
  final DrawStyle style;
  final double width;
  const _WidthSwatch(this.controller, this.style, this.width);
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => controller.setStrokeWidth(width),
    child: Container(
      width: 26,
      height: 22,
      margin: const EdgeInsets.symmetric(horizontal: 2),
      alignment: Alignment.center,
      child: Container(
        width: 20,
        height: width,
        color: style.strokeWidth == width
            ? Colors.lightBlueAccent
            : Colors.white70,
      ),
    ),
  );
}

/// Adjustable font size in points: a directly-typeable number field plus −/+
/// buttons. The buttons are GestureDetectors (not focusable) so they don't blur
/// the text being edited; the number field commits via [onEditingDone].
class _FontControl extends StatefulWidget {
  final EditorController controller;
  final VoidCallback onEditingDone;
  const _FontControl(this.controller, this.onEditingDone);
  @override
  State<_FontControl> createState() => _FontControlState();
}

class _FontControlState extends State<_FontControl> {
  late final TextEditingController _ptCtl;
  final _ptFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _ptCtl = TextEditingController(text: _styleSize);
    widget.controller.style.addListener(_syncFromStyle);
  }

  @override
  void dispose() {
    widget.controller.style.removeListener(_syncFromStyle);
    _ptCtl.dispose();
    _ptFocus.dispose();
    super.dispose();
  }

  String get _styleSize =>
      widget.controller.style.value.fontSize.round().toString();

  void _syncFromStyle() {
    if (_ptFocus.hasFocus) return; // don't fight the user's typing
    if (_ptCtl.text != _styleSize) _ptCtl.text = _styleSize;
  }

  void _setFromText(String s) {
    final v = double.tryParse(s.trim());
    if (v != null) widget.controller.setFontSize(v.clamp(8, 200));
  }

  void _step(double d) => widget.controller.setFontSize(
    (widget.controller.style.value.fontSize + d).clamp(8, 200),
  );

  @override
  Widget build(BuildContext context) {
    Widget btn(IconData icon, VoidCallback onTap) => GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(icon, color: Colors.white70, size: 16),
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        btn(Icons.remove, () => _step(-2)),
        SizedBox(
          width: 36,
          child: TextField(
            controller: _ptCtl,
            focusNode: _ptFocus,
            textAlign: TextAlign.center,
            keyboardType: TextInputType.number,
            style: const TextStyle(color: Colors.white, fontSize: 12),
            decoration: const InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(vertical: 4),
            ),
            onChanged: _setFromText,
            onSubmitted: (_) {
              _ptFocus.unfocus();
              widget.onEditingDone();
            },
            onTapOutside: (_) {},
          ),
        ),
        const Text('pt', style: TextStyle(color: Colors.white54, fontSize: 11)),
        btn(Icons.add, () => _step(2)),
      ],
    );
  }
}
