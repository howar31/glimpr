import 'package:flutter/material.dart';
import '../editor/draw_style.dart';
import '../editor/editor_controller.dart';

/// Bottom-center toolbar: a contextual options row above the main tool row.
class EditorToolbar extends StatelessWidget {
  final EditorController controller;
  const EditorToolbar({super.key, required this.controller});

  static const _tools = <(ToolKind, IconData)>[
    (ToolKind.select, Icons.near_me_outlined),
    (ToolKind.rectangle, Icons.crop_square),
    (ToolKind.arrow, Icons.north_east),
    (ToolKind.text, Icons.title),
    (ToolKind.crop, Icons.crop),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _OptionsRow(controller: controller),
        const SizedBox(height: 6),
        _Bar(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (kind, icon) in _tools)
                ValueListenableBuilder<ToolKind>(
                  valueListenable: controller.tool,
                  builder: (_, active, _) => IconButton(
                    icon: Icon(icon),
                    color: active == kind ? Colors.lightBlueAccent : Colors.white,
                    onPressed: () => controller.selectTool(kind),
                  ),
                ),
            ],
          ),
        ),
      ],
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

/// Color swatches + stroke widths (+ font size for the Text tool), shown only
/// for tools that draw.
class _OptionsRow extends StatelessWidget {
  final EditorController controller;
  const _OptionsRow({required this.controller});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ToolKind>(
      valueListenable: controller.tool,
      builder: (_, tool, _) {
        final showsStyle = tool == ToolKind.rectangle ||
            tool == ToolKind.arrow ||
            tool == ToolKind.text;
        if (!showsStyle) return const SizedBox.shrink();
        return _Bar(
          child: ValueListenableBuilder<DrawStyle>(
            valueListenable: controller.style,
            builder: (_, style, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final c in kColorPresets)
                  GestureDetector(
                    onTap: () => controller.setColor(c),
                    child: Container(
                      width: 18,
                      height: 18,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: style.color == c ? Colors.white : Colors.black26,
                          width: style.color == c ? 2 : 1,
                        ),
                      ),
                    ),
                  ),
                const SizedBox(width: 10),
                for (final w in kStrokeWidths)
                  GestureDetector(
                    onTap: () => controller.setStrokeWidth(w),
                    child: Container(
                      width: 26,
                      height: 22,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      alignment: Alignment.center,
                      child: Container(
                        width: 20,
                        height: w,
                        color: style.strokeWidth == w
                            ? Colors.lightBlueAccent
                            : Colors.white70,
                      ),
                    ),
                  ),
                if (tool == ToolKind.text) ...[
                  const SizedBox(width: 10),
                  for (final s in const [14.0, 18.0, 28.0])
                    GestureDetector(
                      onTap: () => controller.setFontSize(s),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Text('A',
                            style: TextStyle(
                                color: style.fontSize == s
                                    ? Colors.lightBlueAccent
                                    : Colors.white70,
                                fontSize: s.clamp(14, 22))),
                      ),
                    ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
