import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import '../editor/draw_style.dart';
import '../editor/editor_controller.dart';
import '../editor/font_bridge.dart';
import '../editor/tool_meta.dart';
import '../editor/tool_style_store.dart';
import '../settings/settings.dart';
import '../shortcuts/hotkey_binding.dart';
import '../shortcuts/shortcut_actions.dart';
import '../theme/glimpr_theme.dart';
import 'style_popovers.dart';

/// Draggable bottom toolbar: a main tool row with a contextual options row
/// below it. The tool row is the Column's first (top-anchored) child so the
/// options row can grow / collapse downward without ever shifting the tool row.
/// Each tool shows a badge with its CURRENT keyboard shortcut (read from
/// [editorBindings], so a user rebind in Settings is reflected here on the next
/// capture); an unbound tool shows no badge. [onMove] is fed pointer deltas from
/// the drag handle so the host can reposition it.
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
  // Effective editor.* bindings; the per-tool badge is derived from these so it
  // tracks the user's customized shortcut (Tier 2). Empty => no badges.
  final Map<String, HotkeyBinding?> editorBindings;
  const EditorToolbar({
    super.key,
    required this.controller,
    required this.onMove,
    required this.onPtEditingDone,
    this.editorBindings = const {},
  });

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
                for (final (kind, icon) in kEditorToolMeta)
                  _ToolButton(
                    controller: controller,
                    kind: kind,
                    icon: icon,
                    // Badge = the tool's current binding label (e.g. "C", "1",
                    // "⌘B"); null/unbound => no badge.
                    shortcut: editorBindings[kEditorToolActionKey[kind]]?.label(),
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

/// Which contextual popover (if any) is currently open above the toolbar.
enum _OpenPopover { none, color, font }

/// Per-tool options: color (all drawing tools), stroke width (rect/arrow only),
/// font size (text only). Hidden for the Crop tool.
///
/// Beyond the always-visible quick controls (preset colour swatches, the three
/// quick stroke buttons, the font-SIZE field) this row hosts three richer
/// controls: a continuous stroke slider (stroke tools), a custom-colour "+"
/// swatch that opens a [ColorPickerPopover], and a font-FAMILY button (Text
/// tool only) that opens a [FontPickerPopover]. A "reset this tool" icon
/// restores the active tool's factory default style.
///
/// Popover hosting: at most one popover is open at a time; opening one closes
/// the other; a popover dismisses on outside-tap (a full-screen barrier) and on
/// any tool switch. The popover renders ABOVE the floating toolbar via an
/// [OverlayEntry] anchored to its trigger with a [CompositedTransformFollower].
/// All async work (recent colours, font families) runs only when a popover is
/// OPENED (on tap) — never at build time — so a plain build needs neither the
/// platform channel nor the settings store.
class _OptionsRow extends StatefulWidget {
  final EditorController controller;
  final VoidCallback onPtEditingDone;
  const _OptionsRow({required this.controller, required this.onPtEditingDone});

  @override
  State<_OptionsRow> createState() => _OptionsRowState();
}

class _OptionsRowState extends State<_OptionsRow> {
  // Anchors for the two popovers (custom-colour "+" swatch and font button).
  final _colorLink = LayerLink();
  final _fontLink = LayerLink();

  OverlayEntry? _entry;
  _OpenPopover _open = _OpenPopover.none;

  @override
  void initState() {
    super.initState();
    // Switching tools must dismiss any open popover.
    widget.controller.tool.addListener(_onToolChanged);
  }

  @override
  void dispose() {
    widget.controller.tool.removeListener(_onToolChanged);
    _removeEntry();
    super.dispose();
  }

  void _onToolChanged() => _closePopover();

  void _removeEntry() {
    _entry?.remove();
    _entry = null;
  }

  void _closePopover() {
    if (_entry == null) return;
    _removeEntry();
    _open = _OpenPopover.none;
  }

  EditorController get _c => widget.controller;

  // --- popover openers (async work happens HERE, on tap, not at build) -------

  Future<void> _openColorPopover() async {
    // Toggle off if already open; ensure only one popover at a time.
    if (_open == _OpenPopover.color) {
      _closePopover();
      return;
    }
    _closePopover();
    final recents =
        await ToolStyleStore(Settings.instance.store).loadRecentColors();
    if (!mounted) return;
    _showPopover(
      _OpenPopover.color,
      _colorLink,
      width: 240,
      child: ColorPickerPopover(
        color: _c.style.value.color,
        recents: recents,
        onChanged: _c.setColor,
        onCommit: (color) => ToolStyleStore(Settings.instance.store)
            .pushRecentColor(color.toARGB32()),
      ),
    );
  }

  Future<void> _openFontPopover() async {
    if (_open == _OpenPopover.font) {
      _closePopover();
      return;
    }
    _closePopover();
    final families = await FontBridge().availableFamilies();
    if (!mounted) return;
    _showPopover(
      _OpenPopover.font,
      _fontLink,
      width: 260,
      child: FontPickerPopover(
        families: families,
        selected: _c.style.value.fontFamily,
        onSelected: (name) {
          if (name == null) {
            _c.resetFontFamily();
          } else {
            _c.setFontFamily(name);
          }
        },
      ),
    );
  }

  /// Inserts the [OverlayEntry] that hosts [child] above the toolbar, anchored
  /// to [link] and dismissed by a full-screen outside-tap barrier.
  void _showPopover(
    _OpenPopover which,
    LayerLink link, {
    required double width,
    required Widget child,
  }) {
    final palette = _ToolbarTheme.of(context);
    final overlay = Overlay.of(context);
    _entry = OverlayEntry(
      builder: (ctx) => Stack(
        children: [
          // Outside-tap barrier — fills the whole overlay and dismisses.
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _closePopover,
            ),
          ),
          // The popover, anchored just above the trigger (followerAnchor
          // bottom-left -> targetAnchor top-left), so it grows UPWARD.
          CompositedTransformFollower(
            link: link,
            showWhenUnlinked: false,
            targetAnchor: Alignment.topLeft,
            followerAnchor: Alignment.bottomLeft,
            offset: const Offset(0, -8),
            child: Material(
              type: MaterialType.transparency,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: width),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: palette.glassTint,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: palette.glassBorder, width: 0.5),
                    boxShadow: const [
                      BoxShadow(color: Color(0x66000000), blurRadius: 16),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
    overlay.insert(_entry!);
    _open = which;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ToolKind>(
      valueListenable: _c.tool,
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
        // The font-FAMILY button is Text-only (Step has no editable family).
        final showsFontFamily = tool == ToolKind.text;
        return _Bar(
          child: ValueListenableBuilder<DrawStyle>(
            valueListenable: _c.style,
            builder: (_, style, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final c in kColorPresets)
                  _ColorSwatch(_c, style, c),
                // Custom-colour "+" swatch — opens the HSV picker.
                CompositedTransformTarget(
                  link: _colorLink,
                  child: _CustomColorSwatch(onTap: _openColorPopover),
                ),
                if (showsWidth) ...[
                  const SizedBox(width: 10),
                  for (final w in kStrokeWidths)
                    _WidthSwatch(_c, style, w),
                  const SizedBox(width: 6),
                  SizedBox(
                    width: 110,
                    child: Slider(
                      key: const ValueKey('stroke-slider'),
                      min: kStrokeMin,
                      max: kStrokeMax,
                      value: style.strokeWidth.clamp(kStrokeMin, kStrokeMax),
                      onChanged: _c.setStrokeWidth,
                    ),
                  ),
                ],
                if (showsFont) ...[
                  const SizedBox(width: 10),
                  _FontControl(_c, widget.onPtEditingDone),
                ],
                if (showsFontFamily) ...[
                  const SizedBox(width: 8),
                  CompositedTransformTarget(
                    link: _fontLink,
                    child: _FontFamilyButton(
                      key: const ValueKey('font-button'),
                      label: style.fontFamily ?? 'System',
                      onTap: _openFontPopover,
                    ),
                  ),
                ],
                // Reset the active tool's style to the factory default.
                const SizedBox(width: 6),
                _ResetToolButton(
                  key: const ValueKey('reset-tool'),
                  onTap: () => _c.resetTool(_c.tool.value),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A small "+" swatch (rainbow gradient with a centred plus) that opens the
/// bespoke HSV colour picker for a fully custom colour.
class _CustomColorSwatch extends StatelessWidget {
  final VoidCallback onTap;
  const _CustomColorSwatch({required this.onTap});
  @override
  Widget build(BuildContext context) {
    final p = _ToolbarTheme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 18,
        height: 18,
        margin: const EdgeInsets.symmetric(horizontal: 3),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const SweepGradient(
            colors: [
              Color(0xFFFF0000),
              Color(0xFFFFFF00),
              Color(0xFF00FF00),
              Color(0xFF00FFFF),
              Color(0xFF0000FF),
              Color(0xFFFF00FF),
              Color(0xFFFF0000),
            ],
          ),
          border: Border.all(color: p.swatchUnselectedBorder),
        ),
        child: Icon(Icons.add, size: 12, color: p.fg),
      ),
    );
  }
}

/// A compact pill showing the current font family; tapping opens the font
/// picker popover. Text-tool only.
class _FontFamilyButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _FontFamilyButton({super.key, required this.label, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final p = _ToolbarTheme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 110),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: p.swatchUnselectedBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: p.fg, fontSize: 12),
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.arrow_drop_down, size: 16, color: p.fgFaint),
          ],
        ),
      ),
    );
  }
}

/// Reset-this-tool icon: restores the active tool's factory default style.
class _ResetToolButton extends StatelessWidget {
  final VoidCallback onTap;
  const _ResetToolButton({super.key, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final p = _ToolbarTheme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Tooltip(
        message: 'Reset this tool',
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(Icons.restart_alt, size: 18, color: p.fgFaint),
        ),
      ),
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
