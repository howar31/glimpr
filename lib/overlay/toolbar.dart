import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import '../editor/draw_style.dart';
import '../editor/editor_controller.dart';
import '../theme/glimpr_theme.dart';

/// Draggable bottom toolbar: a main tool row with a contextual options row
/// below it. The tool row is the Column's first (top-anchored) child so the
/// options row can grow / collapse downward without ever shifting the tool row.
/// Each tool shows a number badge (its 1-based keyboard shortcut). [onMove] is
/// fed pointer deltas from the drag handle so the host can reposition it.
///
/// The toolbar floats over the frozen screenshot, but its chrome follows the
/// system light/dark appearance (same as the settings window) via a
/// brightness-resolved [_ToolbarPalette]; per-icon/text shadows keep it legible
/// on any backdrop in either theme. The active-tool highlight is the brand
/// accent ([GlimprTokens.accent]) in both themes.
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
  // region tools first on letter keys — C=Crop B=Blur P=Pixelate — then the
  // drawing tools on digits: 1=Rectangle 2=Ellipse 3=Line 4=Arrow 5=Pen 6=Text
  // 7=Highlighter 8=Step 9=Paste.
  static const tools = <(ToolKind, IconData, String?)>[
    (ToolKind.crop, Icons.crop, 'C'),
    (ToolKind.blur, Icons.blur_on, 'B'),
    (ToolKind.pixelate, Icons.grid_on, 'P'),
    (ToolKind.rectangle, Icons.crop_square, '1'),
    (ToolKind.ellipse, Icons.circle_outlined, '2'),
    (ToolKind.line, Icons.horizontal_rule, '3'),
    (ToolKind.arrow, Icons.north_east, '4'),
    (ToolKind.pen, Icons.gesture, '5'),
    (ToolKind.text, Icons.title, '6'),
    (ToolKind.highlighter, Icons.border_color, '7'),
    (ToolKind.step, Icons.looks_one, '8'),
    (ToolKind.paste, Icons.content_paste, '9'),
  ];

  @override
  Widget build(BuildContext context) {
    final palette = _ToolbarPalette.forBrightness(
      MediaQuery.platformBrightnessOf(context),
    );
    return _ToolbarTheme(
      palette: palette,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Main tool row FIRST so it is the top, top-anchored child: the host
          // pins this Column's top-left at _toolbarPos, so the tool row stays put
          // while the contextual options row below it appears / grows / shrinks —
          // it can never displace the tool row the user is aiming at.
          _Bar(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Drag handle — move the whole toolbar out of the way.
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: (d) => onMove(d.delta),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.move,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Icon(
                        Icons.drag_indicator,
                        color: palette.fgDim,
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
          const SizedBox(height: 6),
          _OptionsRow(controller: controller, onPtEditingDone: onPtEditingDone),
        ],
      ),
    );
  }
}

/// Brightness-resolved colors for the toolbar chrome. The accent is the brand
/// blue in both themes; everything else flips with the system appearance.
class _ToolbarPalette {
  const _ToolbarPalette({
    required this.glassTint,
    required this.glassBorder,
    required this.shadows,
    required this.fg,
    required this.fgDim,
    required this.fgFaint,
    required this.badgeOutline,
    required this.swatchUnselectedBorder,
  });

  final Color glassTint;
  final Color glassBorder;
  final List<Shadow> shadows; // legibility halo behind icons/text
  final Color fg; // primary icon / text
  final Color fgDim; // tertiary (drag handle, "pt")
  final Color fgFaint; // secondary (−/+ buttons, unselected width)
  final Color badgeOutline; // crisp 1px outline behind the shortcut badge
  final Color swatchUnselectedBorder;

  // Dark halo behind white marks; light halo behind dark marks — so the toolbar
  // stays legible over any screenshot region in either theme.
  static const _darkShadows = <Shadow>[
    Shadow(color: Color(0xCC000000), blurRadius: 2),
    Shadow(color: Color(0x80000000), blurRadius: 5),
  ];
  static const _lightShadows = <Shadow>[
    Shadow(color: Color(0xE6FFFFFF), blurRadius: 2),
    Shadow(color: Color(0x99FFFFFF), blurRadius: 5),
  ];

  static const dark = _ToolbarPalette(
    glassTint: Color(0x1A222226),
    glassBorder: Color(0x33FFFFFF),
    shadows: _darkShadows,
    fg: Colors.white,
    fgDim: Colors.white54,
    fgFaint: Colors.white70,
    badgeOutline: Color(0xFF000000),
    swatchUnselectedBorder: Colors.black26,
  );

  static const light = _ToolbarPalette(
    glassTint: Color(0x40EEF2F7),
    glassBorder: Color(0x66FFFFFF),
    shadows: _lightShadows,
    fg: Color(0xFF14223B),
    fgDim: Color(0xFF64748B),
    fgFaint: Color(0xFF475569),
    badgeOutline: Color(0xFFFFFFFF),
    swatchUnselectedBorder: Color(0x33000000),
  );

  static _ToolbarPalette forBrightness(Brightness b) =>
      b == Brightness.dark ? dark : light;
}

/// Makes the active [_ToolbarPalette] available to the toolbar's descendants.
class _ToolbarTheme extends InheritedWidget {
  const _ToolbarTheme({required this.palette, required super.child});
  final _ToolbarPalette palette;

  static _ToolbarPalette of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_ToolbarTheme>()!
          .palette;

  @override
  bool updateShouldNotify(_ToolbarTheme oldWidget) =>
      palette != oldWidget.palette;
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
    final p = _ToolbarTheme.of(context);
    return ValueListenableBuilder<ToolKind>(
      valueListenable: controller.tool,
      builder: (_, active, _) {
        final on = active == kind;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            IconButton(
              icon: Icon(icon),
              color: on ? GlimprTokens.accent : p.fg,
              onPressed: () => controller.selectTool(kind),
            ),
            if (shortcut != null)
              Positioned(
                right: 2,
                bottom: 1,
                child: Text(
                  shortcut!,
                  style: TextStyle(
                    fontSize: 10,
                    height: 1,
                    fontWeight: FontWeight.w700,
                    color: on ? GlimprTokens.accent : p.fg,
                    // Crisp 1px outline (8 zero-blur offsets), overriding the
                    // inherited soft glass shadow which smears at this tiny size.
                    shadows: [
                      Shadow(color: p.badgeOutline, offset: const Offset(0.7, 0)),
                      Shadow(color: p.badgeOutline, offset: const Offset(-0.7, 0)),
                      Shadow(color: p.badgeOutline, offset: const Offset(0, 0.7)),
                      Shadow(color: p.badgeOutline, offset: const Offset(0, -0.7)),
                      Shadow(color: p.badgeOutline, offset: const Offset(0.7, 0.7)),
                      Shadow(color: p.badgeOutline, offset: const Offset(0.7, -0.7)),
                      Shadow(color: p.badgeOutline, offset: const Offset(-0.7, 0.7)),
                      Shadow(color: p.badgeOutline, offset: const Offset(-0.7, -0.7)),
                    ],
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
  Widget build(BuildContext context) {
    final p = _ToolbarTheme.of(context);
    // Frosted glass: blur the frozen screenshot behind the bar, a translucent
    // theme-tinted fill over it, plus a faint border. Pure Flutter so it looks
    // identical on macOS + Windows (not native Liquid Glass, which is mac-only).
    // Legibility comes from the per-icon/text shadows (p.shadows), which hold up
    // on any backdrop in either theme.
    const radius = 12.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: p.glassTint,
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: p.glassBorder, width: 0.5),
          ),
          child: IconTheme.merge(
            data: IconThemeData(shadows: p.shadows),
            child: DefaultTextStyle.merge(
              style: TextStyle(shadows: p.shadows),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
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
  Widget build(BuildContext context) {
    final p = _ToolbarTheme.of(context);
    final selected = style.color == color;
    return GestureDetector(
      onTap: () => controller.setColor(color),
      child: Container(
        width: 18,
        height: 18,
        margin: const EdgeInsets.symmetric(horizontal: 3),
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? p.fg : p.swatchUnselectedBorder,
            width: selected ? 2 : 1,
          ),
        ),
      ),
    );
  }
}

class _WidthSwatch extends StatelessWidget {
  final EditorController controller;
  final DrawStyle style;
  final double width;
  const _WidthSwatch(this.controller, this.style, this.width);
  @override
  Widget build(BuildContext context) {
    final p = _ToolbarTheme.of(context);
    return GestureDetector(
      onTap: () => controller.setStrokeWidth(width),
      child: Container(
        width: 26,
        height: 22,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        alignment: Alignment.center,
        child: Container(
          width: 20,
          height: width,
          color: style.strokeWidth == width ? GlimprTokens.accent : p.fgFaint,
        ),
      ),
    );
  }
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
    final p = _ToolbarTheme.of(context);
    Widget btn(IconData icon, VoidCallback onTap) => GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(icon, color: p.fgFaint, size: 16),
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
            style: TextStyle(color: p.fg, fontSize: 12),
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
        Text('pt', style: TextStyle(color: p.fgDim, fontSize: 11)),
        btn(Icons.add, () => _step(2)),
      ],
    );
  }
}
