import 'dart:ui' show ImageFilter;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// Draggable toolbar: a contextual options row ABOVE a main tool row. The tool
/// row is the Column's last (bottom) child and the host bottom-anchors the
/// toolbar, so the tool row stays put while the options row (and any popover)
/// above it grows / collapses upward without ever shifting the tool row.
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
  // Called when a toolbar number field (stroke px / font pt) commits, so the
  // host can hand keyboard focus back to the editor (or the inline text field).
  final VoidCallback onPtEditingDone;
  // Effective editor.* bindings; the per-tool badge is derived from these so it
  // tracks the user's customized shortcut (Tier 2). Empty => no badges.
  final Map<String, HotkeyBinding?> editorBindings;
  // When false the drag-handle icon is hidden (e.g. a docked toolbar that the
  // host positions; the overlay always keeps the handle).
  final bool showDragHandle;
  // Extra action widgets appended inside the same glass tool-row bar, separated
  // by a thin vertical divider (e.g. Copy/Save buttons in the image editor).
  // Empty by default so all existing call sites are unchanged.
  final List<Widget> trailing;
  // Whether to show the mouse-pointer toggle (the capture carried a cursor image —
  // overlay only). Toggles `controller.showCursor`.
  final bool showCursorToggle;
  // The ⌘⌥7 capture-to-pin session: the Crop tool's icon becomes a pin and a
  // caption below the bar names the mode, so it cannot be mistaken for a
  // normal capture. The normal ⌘⌥1 overlay never sets this.
  final bool pinMode;
  const EditorToolbar({
    super.key,
    required this.controller,
    required this.onMove,
    required this.onPtEditingDone,
    this.editorBindings = const {},
    this.showDragHandle = true,
    this.trailing = const [],
    this.showCursorToggle = false,
    this.pinMode = false,
  });

  @override
  Widget build(BuildContext context) {
    final palette = _ToolbarPalette.forBrightness(
      MediaQuery.platformBrightnessOf(context),
    );
    return _ToolbarTheme(
      palette: palette,
      // The toolbar floats at the bottom and every panel/popover grows UPWARD;
      // tooltips must too, or they cover the bar they describe.
      child: TooltipTheme(
        data: const TooltipThemeData(preferBelow: false),
        child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Contextual options row FIRST so it grows UPWARD. The host pins this
          // Column's BOTTOM at the toolbar position, so the tool row (the last,
          // bottom child) stays put while the options row above it appears /
          // grows / shrinks — it can never displace the tool row being aimed at.
          _OptionsRow(
            controller: controller,
            onPtEditingDone: onPtEditingDone,
            editorBindings: editorBindings,
          ),
          const SizedBox(height: 6),
          // Main tool row LAST = the fixed bottom anchor.
          _Bar(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Drag handle — move the whole toolbar out of the way.
                // Hidden when the host docks the toolbar (showDragHandle=false).
                if (showDragHandle)
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
                    // Pin mode: the region tool IS the pin region selector.
                    icon: pinMode && kind == ToolKind.crop
                        ? Icons.push_pin
                        : icon,
                    // Badge = the tool's current binding label (e.g. "C", "1",
                    // "⌘B"); null/unbound => no badge.
                    shortcut: editorBindings[kEditorToolActionKey[kind]]
                        ?.label(),
                  ),
                // Mouse-pointer toggle (overlay, when the capture carried a
                // cursor) — not a tool: shows/hides the captured cursor layer.
                if (showCursorToggle) _CursorToggle(controller: controller),
                // Trailing action widgets (e.g. Copy/Save in the image editor),
                // separated from the tool buttons by a thin vertical divider so
                // they read as part of the same glass bar.
                if (trailing.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Container(
                    width: 1,
                    height: 24,
                    color: palette.fgDim.withValues(alpha: 0.35),
                  ),
                  const SizedBox(width: 8),
                  ...trailing,
                ],
              ],
            ),
          ),
          if (pinMode) ...[
            const SizedBox(height: 6),
            // Mode caption BELOW the bar: names the pin session explicitly.
            _Bar(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.push_pin, size: 13, color: GlimprTokens.accent),
                    const SizedBox(width: 6),
                    Text(
                      'Pin mode — the selection floats as a pin',
                      style: TextStyle(
                        color: palette.fg,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
        ),
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
    Shadow(color: Color(0xB3000000), blurRadius: 1.5),
    Shadow(color: Color(0x4D000000), blurRadius: 2.5),
  ];
  static const _lightShadows = <Shadow>[
    Shadow(color: Color(0xCCFFFFFF), blurRadius: 1.5),
    Shadow(color: Color(0x66FFFFFF), blurRadius: 2.5),
  ];

  static const dark = _ToolbarPalette(
    // Match the settings window's Aurora glass — the same navy tint + bright
    // white border — but at a higher alpha than its winBg (0.10): the settings
    // window gets its translucency from NATIVE desktop vibrancy, whereas the
    // toolbar/popovers only blur the screenshot via Flutter, so a thin tint
    // washes out over light captures. ~0.55 stays frosted yet readable.
    glassTint: Color.fromRGBO(15, 21, 38, 0.55),
    glassBorder: Color.fromRGBO(255, 255, 255, 0.22),
    shadows: _darkShadows,
    fg: Colors.white,
    fgDim: Colors.white54,
    fgFaint: Colors.white70,
    badgeOutline: Color(0xFF000000),
    swatchUnselectedBorder: Colors.black26,
  );

  static const light = _ToolbarPalette(
    // Match the settings window's light Aurora glass (near-white tint + bright
    // border) at a higher alpha than its winBg (0.12) — same reason as dark: no
    // native vibrancy here, so a thin tint washes out over a screenshot.
    glassTint: Color.fromRGBO(249, 251, 253, 0.66),
    glassBorder: Color.fromRGBO(255, 255, 255, 0.70),
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
      context.dependOnInheritedWidgetOfExactType<_ToolbarTheme>()!.palette;

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
                      Shadow(
                        color: p.badgeOutline,
                        offset: const Offset(0.7, 0),
                      ),
                      Shadow(
                        color: p.badgeOutline,
                        offset: const Offset(-0.7, 0),
                      ),
                      Shadow(
                        color: p.badgeOutline,
                        offset: const Offset(0, 0.7),
                      ),
                      Shadow(
                        color: p.badgeOutline,
                        offset: const Offset(0, -0.7),
                      ),
                      Shadow(
                        color: p.badgeOutline,
                        offset: const Offset(0.7, 0.7),
                      ),
                      Shadow(
                        color: p.badgeOutline,
                        offset: const Offset(0.7, -0.7),
                      ),
                      Shadow(
                        color: p.badgeOutline,
                        offset: const Offset(-0.7, 0.7),
                      ),
                      Shadow(
                        color: p.badgeOutline,
                        offset: const Offset(-0.7, -0.7),
                      ),
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

/// Mouse-pointer toggle: shows/hides the captured cursor layer (overlay only).
/// Accent-tinted when on, like an active tool.
class _CursorToggle extends StatelessWidget {
  final EditorController controller;
  const _CursorToggle({required this.controller});
  @override
  Widget build(BuildContext context) {
    final p = _ToolbarTheme.of(context);
    return ValueListenableBuilder<bool>(
      valueListenable: controller.showCursor,
      builder: (_, on, _) => IconButton(
        icon: const Icon(Icons.mouse),
        color: on ? GlimprTokens.accent : p.fg,
        tooltip: on ? 'Mouse pointer: shown' : 'Mouse pointer: hidden',
        onPressed: () => controller.showCursor.value = !on,
      ),
    );
  }
}

/// A compact icon button for selection actions (duplicate / z-order) shown in the
/// option bar whenever a drawable is selected. Sized to match the option-bar
/// pills/steppers rather than the taller tool-row [IconButton].
class _ActionIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _ActionIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final p = _ToolbarTheme.of(context);
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Icon(icon, size: 18, color: p.fg, shadows: p.shadows),
          ),
        ),
      ),
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
enum _OpenPopover {
  none,
  color,
  fill,
  outline,
  radius,
  font,
  texture,
  lineStyle,
  arrowHeads,
  stepShape,
  spotlightEffect,
}

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
  // Effective editor.* bindings, so the selection-action tooltips can show the
  // user's customized shortcut (matches the tool-button badges).
  final Map<String, HotkeyBinding?> editorBindings;
  const _OptionsRow({
    required this.controller,
    required this.onPtEditingDone,
    this.editorBindings = const {},
  });

  @override
  State<_OptionsRow> createState() => _OptionsRowState();
}

class _OptionsRowState extends State<_OptionsRow> {
  // One anchor on the whole options row: the row's height varies with the
  // stroke slider, so anchoring to the row (not a button inside it) lets the
  // popover sit a consistent gap above the entire row, centred over it.
  final _barLink = LayerLink();

  OverlayEntry? _entry;
  _OpenPopover _open = _OpenPopover.none;

  @override
  void initState() {
    super.initState();
    // Switching tools OR changing the selection must dismiss any open popover (it
    // targets the previous subject's style).
    widget.controller.tool.addListener(_onToolChanged);
    widget.controller.selectedIndex.addListener(_onToolChanged);
  }

  @override
  void dispose() {
    widget.controller.tool.removeListener(_onToolChanged);
    widget.controller.selectedIndex.removeListener(_onToolChanged);
    _removeEntry();
    super.dispose();
  }

  void _onToolChanged() => _closePopover();

  /// Tooltip text for a selection-action button: the name plus the user's
  /// current shortcut label (e.g. "Duplicate  ⌘D"), or just the name if unbound.
  String _actionTip(String name, String actionKey) {
    final label = widget.editorBindings[actionKey]?.label();
    return (label == null || label.isEmpty) ? name : '$name  $label';
  }

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

  /// The type the option bar is showing: the SELECTED annotation's type when one
  /// is selected (so the universal Select tool — and any tool — edits the actual
  /// selection), else the active tool.
  ToolKind _effectiveType() {
    final drawables = _c.document.value.drawables;
    final sel = _c.selectedIndex.value;
    if (sel != null && sel >= 0 && sel < drawables.length) {
      final t = toolKindForDrawable(drawables[sel]);
      if (t != null) return t;
    }
    return _c.tool.value;
  }

  // --- popover openers (async work happens HERE, on tap, not at build) -------

  Future<void> _openColorPopover() async {
    // Toggle off if already open; ensure only one popover at a time.
    if (_open == _OpenPopover.color) {
      _closePopover();
      return;
    }
    _closePopover();
    final recents = await ToolStyleStore(
      Settings.instance.store,
    ).loadRecentColors();
    if (!mounted) return;
    _showPopover(
      _OpenPopover.color,
      _barLink,
      // Exact fit for the 7 preset swatches: 7*26 + 6*6 = 218px content + the
      // 12px L/R padding = 242, so the row spans the panel with equal margins.
      width: 242,
      child: ColorPickerPopover(
        color: _c.style.value.color,
        recents: recents,
        // The highlighter shows its translucent quick-picks; everything else the
        // standard palette. Keyed off the EFFECTIVE type so editing a selected
        // highlighter via the Select tool still shows the translucent presets.
        presets: _effectiveType() == ToolKind.highlighter
            ? kHighlighterPresets
            : kColorPresets,
        onChanged: _c.setColor,
        onCommit: (color) => ToolStyleStore(
          Settings.instance.store,
        ).pushRecentColor(color.toARGB32()),
        // Start eyedropper sampling on the canvas; close the popover so the
        // whole frozen frame / editor image is pickable.
        onPickFromScreen: () {
          _c.startEyedropper();
          _closePopover();
        },
      ),
    );
  }

  // The fill picker (rect/ellipse only). Mirrors the outline picker but seeds and
  // writes [DrawStyle.fillColor]; the alpha slider doubles as "drag to 0 = no
  // fill". No eyedropper — that path targets the outline colour.
  Future<void> _openFillPopover() async {
    if (_open == _OpenPopover.fill) {
      _closePopover();
      return;
    }
    _closePopover();
    final recents = await ToolStyleStore(
      Settings.instance.store,
    ).loadRecentColors();
    if (!mounted) return;
    _showPopover(
      _OpenPopover.fill,
      _barLink,
      width: 242,
      child: ColorPickerPopover(
        color: _c.style.value.fillColor,
        recents: recents,
        presets: kColorPresets,
        onChanged: _c.setFillColor,
        // A cleared (transparent) fill isn't a colour worth recalling.
        onCommit: (color) {
          if (color.a > 0) {
            ToolStyleStore(
              Settings.instance.store,
            ).pushRecentColor(color.toARGB32());
          }
        },
      ),
    );
  }

  // The text-outline picker (Text tool only). Mirrors the fill picker but writes
  // [DrawStyle.outlineColor]; alpha 0 = no outline.
  Future<void> _openOutlinePopover() async {
    if (_open == _OpenPopover.outline) {
      _closePopover();
      return;
    }
    _closePopover();
    final recents = await ToolStyleStore(
      Settings.instance.store,
    ).loadRecentColors();
    if (!mounted) return;
    _showPopover(
      _OpenPopover.outline,
      _barLink,
      width: 242,
      child: ColorPickerPopover(
        color: _c.style.value.outlineColor,
        recents: recents,
        presets: kColorPresets,
        onChanged: _c.setOutlineColor,
        onCommit: (color) {
          if (color.a > 0) {
            ToolStyleStore(
              Settings.instance.store,
            ).pushRecentColor(color.toARGB32());
          }
        },
      ),
    );
  }

  // The corner-radius picker (rectangle only): a slider plus an Auto toggle. The
  // child listens to the style so dragging the slider moves its own knob live.
  void _openRadiusPopover() {
    if (_open == _OpenPopover.radius) {
      _closePopover();
      return;
    }
    _closePopover();
    _showPopover(
      _OpenPopover.radius,
      _barLink,
      width: 220,
      child: ValueListenableBuilder<DrawStyle>(
        valueListenable: _c.style,
        builder: (_, st, _) => RadiusPickerPopover(
          value: st.cornerRadius,
          max: kCornerRadiusMax,
          onChanged: _c.setCornerRadius,
          onAuto: _c.setCornerRadiusAuto,
        ),
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
      _barLink,
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

  void _openTexturePopover() {
    if (_open == _OpenPopover.texture) {
      _closePopover();
      return;
    }
    _closePopover();
    _showPopover(
      _OpenPopover.texture,
      _barLink,
      width: 200,
      child: TexturePickerPopover(
        selected: _c.style.value.texture,
        color: _c.style.value.color,
        onSelected: (t) {
          _c.setHighlighterTexture(t);
          _closePopover(); // menu-style: pick closes
          setState(() {}); // refresh the button label
        },
      ),
    );
  }

  void _openLineStylePopover() {
    if (_open == _OpenPopover.lineStyle) {
      _closePopover();
      return;
    }
    _closePopover();
    _showPopover(
      _OpenPopover.lineStyle,
      _barLink,
      width: 300,
      child: LineStylePickerPopover(
        selected: _c.style.value.lineStyle,
        color: _c.style.value.color,
        onSelected: (s) {
          _c.setLineStyle(s);
          _closePopover();
          setState(() {});
        },
      ),
    );
  }

  void _openArrowHeadsPopover() {
    if (_open == _OpenPopover.arrowHeads) {
      _closePopover();
      return;
    }
    _closePopover();
    _showPopover(
      _OpenPopover.arrowHeads,
      _barLink,
      width: 150,
      child: ArrowHeadsPickerPopover(
        selected: _c.style.value.arrowHeads,
        onSelected: (h) {
          _c.setArrowHeads(h);
          _closePopover();
          setState(() {});
        },
      ),
    );
  }

  void _openStepShapePopover() {
    if (_open == _OpenPopover.stepShape) {
      _closePopover();
      return;
    }
    _closePopover();
    _showPopover(
      _OpenPopover.stepShape,
      _barLink,
      width: 150,
      child: StepShapePickerPopover(
        selected: _c.style.value.stepShape,
        onSelected: (s) {
          _c.setStepShape(s);
          _closePopover();
          setState(() {});
        },
      ),
    );
  }

  void _openSpotlightEffectPopover() {
    if (_open == _OpenPopover.spotlightEffect) {
      _closePopover();
      return;
    }
    _closePopover();
    _showPopover(
      _OpenPopover.spotlightEffect,
      _barLink,
      width: 180,
      child: SpotlightEffectPickerPopover(
        selected: _c.style.value.spotlightEffect,
        onSelected: (e) {
          _c.setSpotlightEffect(e);
          _closePopover();
          setState(() {});
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
          // The popover sits a consistent 8px gap above the WHOLE options row
          // and is centred over it (follower bottom-centre -> row top-centre),
          // so it never overlaps the row regardless of the row's height.
          CompositedTransformFollower(
            link: link,
            showWhenUnlinked: false,
            targetAnchor: Alignment.topCenter,
            followerAnchor: Alignment.bottomCenter,
            offset: const Offset(0, -6), // match the tool-row<->options gap
            child: Material(
              type: MaterialType.transparency,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: width),
                // Match the toolbar's frosted glass exactly: a backdrop blur
                // under the same tint + border, so the screenshot behind isn't
                // legible through the panel (the bare tint alone was near-clear).
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: const [
                      BoxShadow(color: Color(0x66000000), blurRadius: 16),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: palette.glassTint,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: palette.glassBorder,
                            width: 0.5,
                          ),
                        ),
                        child: child,
                      ),
                    ),
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
    // Rebuild on tool / selection / document changes: the option bar is driven by
    // the EFFECTIVE type (the selected annotation's type, else the active tool),
    // so the Select tool can edit any selected annotation and a hidden bar appears
    // once something is selected.
    return ListenableBuilder(
      listenable: Listenable.merge(
          [_c.tool, _c.selectedIndex, _c.document, _c.stampImage]),
      builder: (context, _) {
        final tool = _effectiveType();
        // Blur/Pixelate carry no colour but DO have a strength control, so the bar
        // shows for them too (a strength stepper replaces the colour button).
        final isRasterEffect =
            tool == ToolKind.blur || tool == ToolKind.pixelate;
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
          ToolKind.magnify, // border colour
        };
        // The style controls show for color/raster tools (the EFFECTIVE type);
        // the selection-action cluster shows whenever ANYTHING is selected —
        // including a pasted image, which has no style bar at all.
        // Spotlight has no colour; its bar is the dim/effect/feather cluster.
        final isSpotlight = tool == ToolKind.spotlight;
        final hasStyleBar =
            colorTools.contains(tool) || isRasterEffect || isSpotlight;
        final sel = _c.selectedIndex.value;
        final hasSelection =
            sel != null && sel >= 0 && sel < _c.document.value.drawables.length;
        // The stamp tool has no style controls, but its option bar shows a
        // "Choose image" pill so the bar must appear for it too.
        final isStamp = tool == ToolKind.stamp;
        if (!hasStyleBar && !hasSelection && !isStamp) {
          return const SizedBox.shrink();
        }
        // Stroke-width applies to the shape/stroke tools (not text/step).
        const widthTools = {
          ToolKind.rectangle,
          ToolKind.ellipse,
          ToolKind.arrow,
          ToolKind.line,
          ToolKind.pen,
          ToolKind.highlighter,
          ToolKind.magnify, // border width
        };
        final showsWidth = widthTools.contains(tool);
        final isMagnify = tool == ToolKind.magnify;
        // Font size = glyph size for text, badge radius for the numbered step.
        final showsFont = tool == ToolKind.text || tool == ToolKind.step;
        // The font-FAMILY button is Text-only (Step has no editable family).
        final showsFontFamily = tool == ToolKind.text;
        // Drop-shadow toggle: the drawing tools + text/step. Excludes the
        // highlighter (a translucent marker) and the region/select tools.
        const shadowTools = {
          ToolKind.rectangle,
          ToolKind.ellipse,
          ToolKind.line,
          ToolKind.arrow,
          ToolKind.pen,
          ToolKind.text,
          ToolKind.step,
          ToolKind.magnify, // lens drop shadow
        };
        final showsShadow = shadowTools.contains(tool);
        // Curve-points apply to all Segmented line tools; the line-STYLE picker
        // is line/arrow only (the highlighter is a marker — dashing it is
        // inconsistent across its textures); the arrowheads picker is arrow-only.
        const segmentTools = {
          ToolKind.line,
          ToolKind.arrow,
          ToolKind.highlighter,
        };
        final showsCurvePoints = segmentTools.contains(tool);
        final showsLineStyle =
            tool == ToolKind.line || tool == ToolKind.arrow;
        // Fill applies to the closed RectShaped vector shapes; corner radius is
        // rectangle-only (an ellipse has no corners).
        // Fill = a solid fill for the closed shapes AND the background pill for
        // text. Outline (glyph stroke) is text-only.
        const fillTools = {
          ToolKind.rectangle,
          ToolKind.ellipse,
          ToolKind.text,
        };
        final showsFill = fillTools.contains(tool);
        final showsOutline = tool == ToolKind.text;
        // The spotlight hole reuses the Radius pill (per-hole corner radius).
        final showsCornerRadius = tool == ToolKind.rectangle || isSpotlight;
        return CompositedTransformTarget(
          link: _barLink,
          child: _Bar(
            child: ValueListenableBuilder<DrawStyle>(
              valueListenable: _c.style,
              builder: (_, style, _) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isStamp)
                    _TextureButton(
                      key: const ValueKey('stamp-picker'),
                      label: _c.stampImage.value == null
                          ? 'Choose image…'
                          : 'Change image…',
                      tooltip: 'Choose a stamp image',
                      onTap: _c.requestStampPick,
                    ),
                  if (hasStyleBar) ...[
                  // Single colour button: shows the current colour over a
                  // checkerboard (translucency reads) and opens the picker. The
                  // presets live inside the picker now. Hidden for the raster
                  // effects — blur/pixelate have no colour, they get a strength
                  // stepper instead.
                  if (!isRasterEffect && !isSpotlight)
                    _ColorButton(color: style.color, onTap: _openColorPopover),
                  if (showsFill) ...[
                    const SizedBox(width: 6),
                    _ColorButton(
                      key: const ValueKey('fill-color'),
                      color: style.fillColor,
                      // Same field, two readings: a shape fill vs a text backdrop.
                      tooltip: tool == ToolKind.text ? 'Background' : 'Fill',
                      glyph: Icons.format_color_fill,
                      onTap: _openFillPopover,
                    ),
                  ],
                  if (showsOutline) ...[
                    const SizedBox(width: 6),
                    _ColorButton(
                      key: const ValueKey('outline-color'),
                      color: style.outlineColor,
                      tooltip: 'Text outline',
                      glyph: Icons.format_color_text,
                      onTap: _openOutlinePopover,
                    ),
                  ],
                  if (isRasterEffect)
                    _NumberStepper(
                      key: const ValueKey('strength-stepper'),
                      controller: _c,
                      read: (s) => s.strength,
                      write: _c.setStrength,
                      min: 4,
                      max: 64,
                      step: 2,
                      suffix: 'px',
                      leadingIcon: Icons.blur_on,
                      leadingTooltip:
                          tool == ToolKind.blur ? 'Blur strength' : 'Pixel size',
                      onEditingDone: widget.onPtEditingDone,
                    ),
                  if (showsWidth) ...[
                    const SizedBox(width: 10),
                    _NumberStepper(
                      key: const ValueKey('stroke-stepper'),
                      controller: _c,
                      read: (s) => s.strokeWidth,
                      write: _c.setStrokeWidth,
                      min: kStrokeMin,
                      max: kStrokeMax,
                      step: 2,
                      suffix: 'px',
                      leadingIcon: Icons.line_weight,
                      leadingTooltip: 'Stroke width',
                      // Hand keyboard focus back to the editor on commit so tool
                      // shortcuts work again (the font field already does this).
                      onEditingDone: widget.onPtEditingDone,
                    ),
                  ],
                  if (showsCornerRadius) ...[
                    const SizedBox(width: 8),
                    // A self-labeling pill (like Texture / Line-style) instead of a
                    // second bare px stepper: it names itself ("Radius") and shows
                    // the value; the slider + Auto live in its popover, so "Auto"
                    // has a clear home.
                    _TextureButton(
                      key: const ValueKey('radius-picker'),
                      label: 'Radius: ${radiusLabel(style.cornerRadius)}',
                      tooltip: 'Corner radius',
                      onTap: _openRadiusPopover,
                    ),
                  ],
                  if (tool == ToolKind.highlighter) ...[
                    const SizedBox(width: 8),
                    _TextureButton(
                      key: const ValueKey('texture-picker'),
                      label: textureLabel(style.texture),
                      tooltip: 'Highlighter texture',
                      onTap: _openTexturePopover,
                    ),
                  ],
                  if (showsLineStyle) ...[
                    const SizedBox(width: 8),
                    _TextureButton(
                      key: const ValueKey('line-style-picker'),
                      label: lineStyleLabel(style.lineStyle),
                      tooltip: 'Line style',
                      onTap: _openLineStylePopover,
                    ),
                  ],
                  if (showsCurvePoints) ...[
                    const SizedBox(width: 8),
                    _NumberStepper(
                      key: const ValueKey('curve-points-stepper'),
                      controller: _c,
                      read: (s) => s.curvePoints.toDouble(),
                      write: (v) => _c.setCurvePoints(v.round()),
                      min: kCurvePointsMin.toDouble(),
                      max: kCurvePointsMax.toDouble(),
                      step: 1,
                      suffix: 'pts',
                      leadingIcon: Icons.gesture,
                      leadingTooltip: 'Curve points',
                      onEditingDone: widget.onPtEditingDone,
                    ),
                  ],
                  if (tool == ToolKind.arrow) ...[
                    const SizedBox(width: 8),
                    _TextureButton(
                      key: const ValueKey('arrow-heads-picker'),
                      label: arrowHeadsLabel(style.arrowHeads),
                      tooltip: 'Arrowheads',
                      onTap: _openArrowHeadsPopover,
                    ),
                    const SizedBox(width: 8),
                    _NumberStepper(
                      key: const ValueKey('arrow-head-scale-stepper'),
                      controller: _c,
                      // The multiplier reads more naturally as a percentage.
                      read: (s) => s.arrowHeadScale * 100,
                      write: (v) => _c.setArrowHeadScale(v / 100),
                      min: kArrowHeadScaleMin * 100,
                      max: kArrowHeadScaleMax * 100,
                      step: 25,
                      suffix: '%',
                      leadingIcon: Icons.arrow_right_alt,
                      leadingTooltip: 'Arrowhead size',
                      onEditingDone: widget.onPtEditingDone,
                    ),
                  ],
                  if (showsFont) ...[
                    const SizedBox(width: 10),
                    _NumberStepper(
                      controller: _c,
                      read: (s) => s.fontSize,
                      write: _c.setFontSize,
                      min: 8,
                      max: 200,
                      step: 2,
                      suffix: 'pt',
                      leadingIcon: Icons.format_size,
                      leadingTooltip:
                          tool == ToolKind.text ? 'Font size' : 'Badge size',
                      onEditingDone: widget.onPtEditingDone,
                    ),
                  ],
                  if (tool == ToolKind.step) ...[
                    const SizedBox(width: 8),
                    _NumberStepper(
                      key: const ValueKey('step-start-stepper'),
                      controller: _c,
                      read: (s) => s.stepStart.toDouble(),
                      write: (v) => _c.setStepStart(v.round()),
                      min: kStepStartMin.toDouble(),
                      max: kStepStartMax.toDouble(),
                      step: 1,
                      suffix: '',
                      leadingIcon: Icons.tag,
                      leadingTooltip: 'Start number',
                      onEditingDone: widget.onPtEditingDone,
                    ),
                    const SizedBox(width: 8),
                    _TextureButton(
                      key: const ValueKey('step-shape-picker'),
                      label: stepShapeLabel(style.stepShape),
                      tooltip: 'Badge shape',
                      onTap: _openStepShapePopover,
                    ),
                  ],
                  if (showsFontFamily) ...[
                    const SizedBox(width: 8),
                    _FontFamilyButton(
                      key: const ValueKey('font-button'),
                      label: style.fontFamily ?? 'System',
                      onTap: _openFontPopover,
                    ),
                  ],
                  if (isSpotlight) ...[
                    _NumberStepper(
                      key: const ValueKey('spotlight-dim-stepper'),
                      controller: _c,
                      read: (s) => s.spotlightDim.toDouble(),
                      write: (v) => _c.setSpotlightDim(v.round()),
                      min: kSpotlightDimMin.toDouble(),
                      max: kSpotlightDimMax.toDouble(),
                      step: 5,
                      suffix: '%',
                      leadingIcon: Icons.brightness_6,
                      leadingTooltip: 'Background dim',
                      onEditingDone: widget.onPtEditingDone,
                    ),
                    const SizedBox(width: 8),
                    _TextureButton(
                      key: const ValueKey('spotlight-effect-picker'),
                      label: spotlightEffectLabel(style.spotlightEffect),
                      tooltip: 'Background treatment',
                      onTap: _openSpotlightEffectPopover,
                    ),
                    if (style.spotlightEffect != SpotlightEffect.none) ...[
                      const SizedBox(width: 8),
                      _NumberStepper(
                        key: const ValueKey('spotlight-strength-stepper'),
                        controller: _c,
                        read: (s) => s.strength,
                        write: _c.setStrength,
                        min: 4,
                        max: 64,
                        step: 2,
                        suffix: 'px',
                        leadingIcon:
                            style.spotlightEffect == SpotlightEffect.blur
                                ? Icons.blur_on
                                : Icons.grid_on,
                        leadingTooltip:
                            style.spotlightEffect == SpotlightEffect.blur
                                ? 'Blur strength'
                                : 'Pixel size',
                        onEditingDone: widget.onPtEditingDone,
                      ),
                    ],
                    const SizedBox(width: 8),
                    _NumberStepper(
                      key: const ValueKey('spotlight-feather-stepper'),
                      controller: _c,
                      read: (s) => s.spotlightFeather,
                      write: _c.setSpotlightFeather,
                      min: kSpotlightFeatherMin,
                      max: kSpotlightFeatherMax,
                      step: 2,
                      suffix: 'px',
                      leadingIcon: Icons.blur_linear,
                      leadingTooltip: 'Edge feather',
                      onEditingDone: widget.onPtEditingDone,
                    ),
                  ],
                  if (isMagnify) ...[
                    const SizedBox(width: 8),
                    _NumberStepper(
                      key: const ValueKey('magnify-factor-stepper'),
                      controller: _c,
                      read: (s) => s.magnifyFactor * 100,
                      write: (v) => _c.setMagnifyFactor(v / 100),
                      min: kMagnifyFactorMin * 100,
                      max: kMagnifyFactorMax * 100,
                      step: 50,
                      suffix: '%',
                      leadingIcon: Icons.zoom_in,
                      leadingTooltip: 'Magnification',
                      onEditingDone: widget.onPtEditingDone,
                    ),
                    const SizedBox(width: 6),
                    _ConnectorToggle(
                      key: const ValueKey('magnify-connector-toggle'),
                      on: style.magnifyConnector,
                      onTap: () =>
                          _c.setMagnifyConnector(!style.magnifyConnector),
                    ),
                  ],
                  if (showsShadow) ...[
                    const SizedBox(width: 6),
                    _ShadowToggle(
                      key: const ValueKey('shadow-toggle'),
                      on: style.shadow,
                      onTap: () => _c.setShadow(!style.shadow),
                    ),
                  ],
                  // Reset the active tool's style to the factory default.
                  const SizedBox(width: 6),
                  _ResetToolButton(
                    key: const ValueKey('reset-tool'),
                    enabled: style != defaultStyleFor(tool),
                    onTap: () => _c.resetActiveStyle(tool),
                  ),
                  ],
                  // Selection actions (duplicate / z-order): shown whenever an
                  // annotation is selected, INCLUDING a pasted image (which has
                  // no style bar). A thin divider separates them from the style
                  // group when both are present.
                  if (hasSelection) ...[
                    if (hasStyleBar) ...[
                      const SizedBox(width: 8),
                      Container(
                        width: 1,
                        height: 24,
                        color: _ToolbarTheme.of(context)
                            .fgDim
                            .withValues(alpha: 0.35),
                      ),
                      const SizedBox(width: 8),
                    ],
                    _ActionIconButton(
                      icon: Icons.content_copy,
                      tooltip: _actionTip('Duplicate', kEditorDuplicateKey),
                      onTap: _c.duplicateSelected,
                    ),
                    const SizedBox(width: 4),
                    _ActionIconButton(
                      icon: Icons.flip_to_front,
                      tooltip:
                          _actionTip('Bring to front', kEditorBringToFrontKey),
                      onTap: _c.bringSelectedToFront,
                    ),
                    const SizedBox(width: 4),
                    _ActionIconButton(
                      icon: Icons.flip_to_back,
                      tooltip: _actionTip('Send to back', kEditorSendToBackKey),
                      onTap: _c.sendSelectedToBack,
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Highlighter-only: a compact pill showing the current brush texture name;
/// tapping opens the [TexturePickerPopover] (a named menu with previews).
class _TextureButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final String? tooltip; // names the control on hover (e.g. "Line style")
  const _TextureButton({
    super.key,
    required this.label,
    required this.onTap,
    this.tooltip,
  });
  @override
  Widget build(BuildContext context) {
    final p = _ToolbarTheme.of(context);
    final pill = GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: p.swatchUnselectedBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: TextStyle(color: p.fg, fontSize: 12)),
            const SizedBox(width: 4),
            Icon(Icons.arrow_drop_down, size: 16, color: p.fgFaint),
          ],
        ),
      ),
    );
    return tooltip == null ? pill : Tooltip(message: tooltip!, child: pill);
  }
}

/// The single colour control: a rounded-rect button showing the current colour
/// over an alpha checkerboard (so a translucent colour reads as translucent),
/// tapped to open the colour picker. No selection ring / glyph — the fill IS the
/// state; the presets live inside the picker.
class _ColorButton extends StatelessWidget {
  final Color color;
  final VoidCallback onTap;
  final String tooltip;
  // Optional glyph overlaid centre to tell two swatches apart (the fill swatch
  // carries a fill-bucket icon; the outline swatch carries none).
  final IconData? glyph;
  const _ColorButton({
    super.key,
    required this.color,
    required this.onTap,
    this.tooltip = 'Colour',
    this.glyph,
  });
  @override
  Widget build(BuildContext context) {
    final p = _ToolbarTheme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Tooltip(
        message: tooltip,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            width: 36,
            height: 22,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: p.swatchUnselectedBorder),
            ),
            // Checker + colour as sibling fill layers — StackFit.expand forces
            // both to the identical rect, so the colour can't end up narrower
            // than the checker. A translucent colour lets the checker read
            // through uniformly; an opaque one fully covers it.
            child: Stack(
              fit: StackFit.expand,
              children: [
                const CustomPaint(painter: _CheckerPainter()),
                ColoredBox(color: color),
                if (glyph != null)
                  // Fixed white-on-shadow so the glyph stays legible over any
                  // fill colour and over the bare checker (no fill).
                  Center(
                    child: Icon(
                      glyph,
                      size: 13,
                      color: const Color(0xF0FFFFFF),
                      shadows: const [
                        Shadow(color: Color(0x99000000), blurRadius: 2),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// An alpha checkerboard, drawn behind the colour so transparency reads the way
/// image editors show it.
class _CheckerPainter extends CustomPainter {
  const _CheckerPainter();
  @override
  void paint(Canvas canvas, Size size) {
    const cell = 5.0;
    canvas.clipRect(Offset.zero & size); // never paint past our own bounds
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFFFFFFF));
    final dark = Paint()..color = const Color(0xFFC8C8C8);
    for (var y = 0.0; y < size.height; y += cell) {
      for (var x = 0.0; x < size.width; x += cell) {
        if (((x ~/ cell) + (y ~/ cell)).isOdd) {
          canvas.drawRect(Rect.fromLTWH(x, y, cell, cell), dark);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_CheckerPainter old) => false;
}

/// A compact pill showing the current font family; tapping opens the font
/// picker popover. Text-tool only.
class _FontFamilyButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _FontFamilyButton({
    super.key,
    required this.label,
    required this.onTap,
  });
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

/// Drop-shadow toggle: a small two-square glyph (a solid object casting an
/// offset shadow) that turns the active tool's drop shadow on/off. Accent-tinted
/// when ON, plus an active-state background ring. Shown for the drawing tools +
/// text/step (see [shadowTools]).
class _ShadowToggle extends StatefulWidget {
  final bool on;
  final VoidCallback onTap;
  const _ShadowToggle({super.key, required this.on, required this.onTap});
  @override
  State<_ShadowToggle> createState() => _ShadowToggleState();
}

class _ShadowToggleState extends State<_ShadowToggle> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final p = _ToolbarTheme.of(context);
    final on = widget.on;
    final base = on ? GlimprTokens.accent : p.fg;
    Widget square(Color c) => DecoratedBox(
      decoration: BoxDecoration(
        color: c,
        borderRadius: BorderRadius.circular(3),
      ),
    );
    final glyph = SizedBox(
      width: 18,
      height: 18,
      child: Stack(
        children: [
          // The offset shadow square (drawn behind).
          Positioned(
            left: 5,
            top: 5,
            right: 0,
            bottom: 0,
            child: square(base.withValues(alpha: 0.4)),
          ),
          // The solid object square on top.
          Positioned(left: 0, top: 0, right: 5, bottom: 5, child: square(base)),
        ],
      ),
    );
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Tooltip(
          message: on ? 'Drop shadow: on' : 'Drop shadow: off',
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: (on || _hover) ? p.glassBorder : Colors.transparent,
            ),
            child: glyph,
          ),
        ),
      ),
    );
  }
}

/// Magnify connector toggle: turns the source->inset connector line on/off.
/// Same accent-on container styling as [_ShadowToggle] but a connector-line glyph
/// + its own tooltip, so it does not read as the drop-shadow control.
class _ConnectorToggle extends StatefulWidget {
  final bool on;
  final VoidCallback onTap;
  const _ConnectorToggle({super.key, required this.on, required this.onTap});
  @override
  State<_ConnectorToggle> createState() => _ConnectorToggleState();
}

class _ConnectorToggleState extends State<_ConnectorToggle> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final p = _ToolbarTheme.of(context);
    final on = widget.on;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Tooltip(
          message: on ? 'Connector line: on' : 'Connector line: off',
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: (on || _hover) ? p.glassBorder : Colors.transparent,
            ),
            child: Icon(Icons.polyline,
                size: 18, color: on ? GlimprTokens.accent : p.fg),
          ),
        ),
      ),
    );
  }
}

/// Reset-this-tool icon: restores the active tool's factory default style.
/// Disabled + dimmed when the tool is ALREADY at its default (same model as the
/// Settings per-row reset); a hover highlight + click cursor signal it is
/// clickable when enabled.
class _ResetToolButton extends StatefulWidget {
  final VoidCallback onTap;
  final bool enabled;
  const _ResetToolButton({
    super.key,
    required this.onTap,
    required this.enabled,
  });
  @override
  State<_ResetToolButton> createState() => _ResetToolButtonState();
}

class _ResetToolButtonState extends State<_ResetToolButton> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final p = _ToolbarTheme.of(context);
    final icon = Padding(
      padding: const EdgeInsets.all(4),
      child: Icon(
        Icons.restart_alt,
        size: 18,
        color: (widget.enabled && _hover) ? p.fg : p.fgFaint,
      ),
    );
    // Already at default -> dim + non-interactive (mirrors Settings reset rows).
    if (!widget.enabled) return Opacity(opacity: 0.25, child: icon);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Tooltip(
          message: 'Reset this tool',
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _hover ? p.glassBorder : Colors.transparent,
            ),
            child: icon,
          ),
        ),
      ),
    );
  }
}

/// Compact `− N + <suffix>` numeric stepper — the unified style for every
/// option bar's numeric control (stroke width "px", font size "pt"). A centred
/// directly-typeable field plus −/+ buttons; the buttons are GestureDetectors
/// (not focusable) so they don't blur the inline text being edited.
class _NumberStepper extends StatefulWidget {
  final EditorController controller;
  final double Function(DrawStyle) read; // current value from the style
  final void Function(double) write; // apply a clamped value
  final double min;
  final double max;
  final double step;
  final String suffix; // "px" / "pt"
  final VoidCallback? onEditingDone; // re-focus inline text (font only)
  // Optional leading pictogram that names what the stepper adjusts (e.g. a
  // line-weight glyph for stroke width), so two numeric fields are never
  // ambiguous at a glance. [leadingTooltip] explains the glyph on hover.
  final IconData? leadingIcon;
  final String? leadingTooltip;
  const _NumberStepper({
    super.key,
    required this.controller,
    required this.read,
    required this.write,
    required this.min,
    required this.max,
    required this.step,
    required this.suffix,
    this.onEditingDone,
    this.leadingIcon,
    this.leadingTooltip,
  });
  @override
  State<_NumberStepper> createState() => _NumberStepperState();
}

class _NumberStepperState extends State<_NumberStepper> {
  late final TextEditingController _ctl;
  final _focus = FocusNode();
  double? _editStart; // value when editing began, for Esc-revert

  @override
  void initState() {
    super.initState();
    _ctl = TextEditingController(text: _value);
    widget.controller.style.addListener(_syncFromStyle);
    _focus.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    widget.controller.style.removeListener(_syncFromStyle);
    _focus.removeListener(_onFocusChange);
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  String get _value =>
      widget.read(widget.controller.style.value).round().toString();

  void _onFocusChange() {
    if (_focus.hasFocus) {
      _editStart ??= widget.read(widget.controller.style.value); // snapshot
    } else {
      _editStart = null;
      // On unfocus, show the real APPLIED value: an out-of-range entry (e.g.
      // 1213 for a 1..40 stroke) is clamped live in _setFromText, and an emptied
      // field made no write — either way realign the label to the actual value.
      if (_ctl.text != _value) _ctl.text = _value;
    }
  }

  void _syncFromStyle() {
    if (_focus.hasFocus) return; // don't fight the user's typing
    if (_ctl.text != _value) _ctl.text = _value;
  }

  void _setFromText(String s) {
    final v = double.tryParse(s.trim());
    if (v != null) widget.write(v.clamp(widget.min, widget.max));
  }

  // Set [v] on the style AND the field text, so +/- update the displayed number
  // even while the field has focus (where _syncFromStyle defers to the typist).
  void _set(double v) {
    final c = v.clamp(widget.min, widget.max);
    widget.write(c);
    final s = c.round().toString();
    if (_ctl.text != s) _ctl.text = s;
  }

  void _bump(double d) => _set(widget.read(widget.controller.style.value) + d);

  // Commit: keep the value, drop focus, hand keyboard focus back to the editor.
  // Unfocusing realigns the displayed text to the applied value (_onFocusChange).
  void _commit() {
    _editStart = null;
    if (_focus.hasFocus) _focus.unfocus();
    widget.onEditingDone?.call();
  }

  // Cancel: revert to the value when editing began, then commit.
  void _cancel() {
    final start = _editStart;
    if (start != null) _set(start);
    _commit();
  }

  // Intercept Enter/Esc so they confirm/cancel the field instead of bubbling to
  // the editor (which treats Enter as export and Esc as exit-capture).
  KeyEventResult _onFieldKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      _commit();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape) {
      _cancel();
      return KeyEventResult.handled;
    }
    // While focused the field owns all plain keys, so typing digits doesn't fire
    // the editor's tool shortcuts; Cmd/Ctrl/Alt combos still reach the editor.
    final combo =
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed;
    // skipRemainingHandlers (NOT handled): stop the key reaching the editor's
    // ancestor _onKey (no tool-shortcut leak) yet report it unhandled so the
    // platform still inserts the character into the field. Returning `handled`
    // here suppressed the platform text insertion entirely — i.e. you couldn't
    // type. Combos pass through (ignored) so editor commands like ⌘V still work.
    return combo
        ? KeyEventResult.ignored
        : KeyEventResult.skipRemainingHandlers;
  }

  double _scrollAccum = 0; // accumulates scroll delta -> one ±1 step per notch

  // Scroll wheel over the stepper (while focused) nudges by ±1 per notch. The
  // delta is accumulated so a trackpad's fine-grained event stream steps once
  // per notch rather than racing through the range.
  void _onScroll(PointerSignalEvent signal) {
    if (signal is! PointerScrollEvent || !_focus.hasFocus) return;
    const notch = 50.0; // logical px of scroll per ±1
    _scrollAccum += signal.scrollDelta.dy;
    var steps = 0;
    while (_scrollAccum <= -notch) {
      _scrollAccum += notch;
      steps++;
    }
    while (_scrollAccum >= notch) {
      _scrollAccum -= notch;
      steps--;
    }
    if (steps != 0) _set(widget.read(widget.controller.style.value) + steps);
  }

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
    return Listener(
      onPointerSignal: _onScroll,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.leadingIcon != null) ...[
            if (widget.leadingTooltip != null)
              Tooltip(
                message: widget.leadingTooltip!,
                child: Icon(widget.leadingIcon, color: p.fgDim, size: 15),
              )
            else
              Icon(widget.leadingIcon, color: p.fgDim, size: 15),
            const SizedBox(width: 2),
          ],
          btn(Icons.remove, () => _bump(-widget.step)),
          SizedBox(
            width: 36,
            child: Focus(
              onKeyEvent: _onFieldKey,
              child: TextField(
                controller: _ctl,
                focusNode: _focus,
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                // Stroke/size are integers — only digits are typeable (the
                // keyboardType hint isn't enforced on desktop hardware keyboards).
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: TextStyle(color: p.fg, fontSize: 12),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 4),
                ),
                onChanged: _setFromText,
                onSubmitted: (_) => _commit(),
                // Tapping anywhere outside the field commits + unfocuses.
                onTapOutside: (_) {
                  if (_focus.hasFocus) _commit();
                },
              ),
            ),
          ),
          Text(widget.suffix, style: TextStyle(color: p.fgDim, fontSize: 11)),
          btn(Icons.add, () => _bump(widget.step)),
        ],
      ),
    );
  }
}
