import 'package:flutter/material.dart';
import '../editor/color_math.dart';
import '../editor/curve.dart' show drawStyledPath;
import '../editor/draw_style.dart';
import '../editor/drawable_painter.dart' show paintHighlighterStroke;
import '../theme/glimpr_controls.dart' show GlimprSlider, GlassToggle;
import '../theme/glimpr_theme.dart';

// ignore_for_file: use_super_parameters

// ---------------------------------------------------------------------------
// ColorPickerPopover
// ---------------------------------------------------------------------------

/// A bespoke HSV colour picker popover.
///
/// Exposes:
/// - Preset swatches from [kColorPresets]
/// - A hue slider (rainbow gradient track)
/// - An SV plane (saturation × value 2-D selector)
/// - An alpha slider (checkerboard-backed, transparent→opaque)
/// - A hex text field (#AARRGGBB or #RRGGBB)
/// - A recents row (MRU ARGB ints)
///
/// [onChanged] is called on every live drag / tap / keystroke.
/// [onCommit] is called when an interaction ends (drag end, tap, field submit).
class ColorPickerPopover extends StatefulWidget {
  const ColorPickerPopover({
    Key? key,
    required this.color,
    required this.recents,
    required this.onChanged,
    required this.onCommit,
    this.onPickFromScreen,
    this.presets = kColorPresets,
  }) : super(key: key);

  final Color color;

  /// Quick-pick swatches shown at the top (tool-dependent: e.g. the highlighter
  /// passes its translucent palette).
  final List<Color> presets;

  /// MRU list of ARGB ints to show as recent swatches.
  final List<int> recents;

  /// Called on every live change (drag, tap preset, valid hex entry).
  final ValueChanged<Color> onChanged;

  /// Called when an interaction completes (drag end, tap, field submit).
  final ValueChanged<Color> onCommit;

  /// Tapped the eyedropper button — start sampling a colour from the canvas.
  /// Null hides the button (e.g. surfaces with no canvas to sample).
  final VoidCallback? onPickFromScreen;

  @override
  State<ColorPickerPopover> createState() => _ColorPickerPopoverState();
}

class _ColorPickerPopoverState extends State<ColorPickerPopover> {
  late Color _color;
  late TextEditingController _hexCtrl;

  @override
  void initState() {
    super.initState();
    _color = widget.color;
    _hexCtrl = TextEditingController(text: colorToHex(_color));
  }

  @override
  void didUpdateWidget(ColorPickerPopover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.color != oldWidget.color) {
      _color = widget.color;
      _hexCtrl.text = colorToHex(_color);
    }
  }

  @override
  void dispose() {
    _hexCtrl.dispose();
    super.dispose();
  }

  // ---- helper: notify both callbacks (live + commit) ----------------------

  void _emitCommit(Color c) {
    setState(() {
      _color = c;
      _hexCtrl.text = colorToHex(c);
    });
    widget.onChanged(c);
    widget.onCommit(c);
  }

  // ---- HSV helpers ---------------------------------------------------------

  HSVColor get _hsv => HSVColor.fromColor(_color);

  // ---- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildPresets(),
            const SizedBox(height: 10),
            _buildSVPlane(),
            const SizedBox(height: 10),
            _buildHueSlider(),
            const SizedBox(height: 8),
            _buildAlphaSlider(),
            const SizedBox(height: 10),
            _buildHexField(),
            if (widget.recents.isNotEmpty) ...[
              const SizedBox(height: 10),
              _buildRecents(),
            ],
          ],
        ),
      ),
    );
  }

  // ---- preset swatches -----------------------------------------------------

  Widget _buildPresets() {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: widget.presets.map((c) {
        final argb = c.toARGB32();
        final keyStr = 'preset-0x${argb.toRadixString(16).toUpperCase()}';
        return GestureDetector(
          key: ValueKey(keyStr),
          onTap: () => _emitCommit(c),
          child: _Swatch(color: c, selected: c == _color),
        );
      }).toList(),
    );
  }

  // ---- SV plane ------------------------------------------------------------

  Widget _buildSVPlane() {
    return SizedBox(
      width: double.infinity,
      height: 140,
      child: _SVPlane(
        hsv: _hsv,
        onChanged: (c) {
          setState(() => _color = c);
          _hexCtrl.text = colorToHex(c);
          widget.onChanged(c);
        },
        onCommit: (c) {
          setState(() {
            _color = c;
            _hexCtrl.text = colorToHex(c);
          });
          widget.onChanged(c);
          widget.onCommit(c);
        },
      ),
    );
  }

  // ---- hue slider ----------------------------------------------------------

  Widget _buildHueSlider() {
    return _GradientSlider(
      value: _hsv.hue / 360.0,
      gradient: const LinearGradient(
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
      onChanged: (v) {
        final c = _hsv.withHue(v * 360.0).toColor();
        setState(() => _color = c);
        _hexCtrl.text = colorToHex(c);
        widget.onChanged(c);
      },
      onCommit: (v) {
        final c = _hsv.withHue(v * 360.0).toColor();
        setState(() {
          _color = c;
          _hexCtrl.text = colorToHex(c);
        });
        widget.onChanged(c);
        widget.onCommit(c);
      },
    );
  }

  // ---- alpha slider --------------------------------------------------------

  Widget _buildAlphaSlider() {
    final opaque = _color.withValues(alpha: 1.0);
    return _GradientSlider(
      value: _color.a,
      gradient: LinearGradient(colors: [const Color(0x00000000), opaque]),
      checkerboard: true,
      onChanged: (v) {
        final c = _color.withValues(alpha: v);
        setState(() => _color = c);
        _hexCtrl.text = colorToHex(c);
        widget.onChanged(c);
      },
      onCommit: (v) {
        final c = _color.withValues(alpha: v);
        setState(() {
          _color = c;
          _hexCtrl.text = colorToHex(c);
        });
        widget.onChanged(c);
        widget.onCommit(c);
      },
    );
  }

  // ---- hex field -----------------------------------------------------------

  Widget _buildHexField() {
    if (widget.onPickFromScreen == null) return _hexTextField();
    // Hex field + eyedropper as two equal-height (34px) bordered boxes so the row
    // reads as one unit; the TextField itself is borderless inside its box.
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 34,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.white24),
            ),
            child: _hexTextField(bordered: false),
          ),
        ),
        const SizedBox(width: 6),
        _EyedropperButton(onTap: widget.onPickFromScreen!),
      ],
    );
  }

  Widget _hexTextField({bool bordered = true}) {
    const outline = OutlineInputBorder(
      borderSide: BorderSide(color: Colors.white24),
    );
    return TextField(
      key: const ValueKey('hex-field'),
      controller: _hexCtrl,
      decoration: InputDecoration(
        isDense: true,
        contentPadding: bordered
            ? const EdgeInsets.symmetric(horizontal: 8, vertical: 8)
            : const EdgeInsets.symmetric(horizontal: 4),
        // Borderless when embedded in a bordered Container (height-matched with
        // the eyedropper); standalone keeps its own outline.
        border: bordered ? outline : InputBorder.none,
        enabledBorder: bordered ? outline : InputBorder.none,
        focusedBorder: bordered
            ? const OutlineInputBorder(
                borderSide: BorderSide(color: Colors.white54),
              )
            : InputBorder.none,
        hintText: '#RRGGBB or #AARRGGBB',
        hintStyle: const TextStyle(color: Colors.white38, fontSize: 12),
      ),
      cursorColor: Colors.white,
      style: const TextStyle(
        fontFamily: 'monospace',
        fontSize: 13,
        color: Colors.white,
      ),
      textInputAction: TextInputAction.done,
      onSubmitted: (text) {
        final parsed = hexToColor(text);
        if (parsed != null) {
          setState(() {
            _color = parsed;
            _hexCtrl.text = colorToHex(parsed);
          });
          widget.onChanged(parsed);
          widget.onCommit(parsed);
        } else {
          // Revert to current colour's hex
          _hexCtrl.text = colorToHex(_color);
        }
      },
    );
  }

  // ---- recents row ---------------------------------------------------------

  Widget _buildRecents() {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: widget.recents.map((argb) {
        final c = Color(argb);
        return GestureDetector(
          onTap: () => _emitCommit(c),
          child: _Swatch(color: c, selected: c == _color),
        );
      }).toList(),
    );
  }
}

// ---------------------------------------------------------------------------
// _SVPlane
// ---------------------------------------------------------------------------

/// A 2-D saturation × value selector painted as a white→hue horizontal
/// gradient (saturation) over a transparent→black vertical gradient (value).
class _SVPlane extends StatelessWidget {
  const _SVPlane({
    required this.hsv,
    required this.onChanged,
    required this.onCommit,
  });

  final HSVColor hsv;
  final ValueChanged<Color> onChanged;
  final ValueChanged<Color> onCommit;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) {
            final c = _posToColor(d.localPosition, size);
            onChanged(c);
          },
          onTapUp: (d) {
            final c = _posToColor(d.localPosition, size);
            onCommit(c);
          },
          onPanUpdate: (d) {
            final c = _posToColor(d.localPosition, size);
            onChanged(c);
          },
          onPanEnd: (_) {
            // Emit current HSV as commit
            onCommit(hsv.toColor());
          },
          child: CustomPaint(size: size, painter: _SVPlanePainter(hsv)),
        );
      },
    );
  }

  Color _posToColor(Offset local, Size size) {
    final s = (local.dx / size.width).clamp(0.0, 1.0);
    final v = 1.0 - (local.dy / size.height).clamp(0.0, 1.0);
    return hsv.withSaturation(s).withValue(v).toColor();
  }
}

class _SVPlanePainter extends CustomPainter {
  _SVPlanePainter(this.hsv);
  final HSVColor hsv;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // White → hue (saturation axis, horizontal)
    final satGrad = LinearGradient(
      colors: [
        const Color(0xFFFFFFFF),
        HSVColor.fromAHSV(1.0, hsv.hue, 1.0, 1.0).toColor(),
      ],
    );
    canvas.drawRect(rect, Paint()..shader = satGrad.createShader(rect));

    // Transparent → black (value axis, vertical)
    const valGrad = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [Color(0x00000000), Color(0xFF000000)],
    );
    canvas.drawRect(rect, Paint()..shader = valGrad.createShader(rect));

    // Draw the current selection cursor
    final x = hsv.saturation * size.width;
    final y = (1.0 - hsv.value) * size.height;
    final cursorPaint = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawCircle(Offset(x, y), 7, cursorPaint);
    final innerPaint = Paint()
      ..color = hsv.toColor()
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(x, y), 6, innerPaint);
  }

  @override
  bool shouldRepaint(_SVPlanePainter old) => old.hsv != hsv;
}

// ---------------------------------------------------------------------------
// _GradientSlider
// ---------------------------------------------------------------------------

/// The colour-picker eyedropper trigger. A bordered 34px box with a clear hover
/// state (fill + brighter border/icon) so it reads as interactive — the previous
/// InkResponse gave no visible hover on this surface.
class _EyedropperButton extends StatefulWidget {
  const _EyedropperButton({required this.onTap});
  final VoidCallback onTap;
  @override
  State<_EyedropperButton> createState() => _EyedropperButtonState();
}

class _EyedropperButtonState extends State<_EyedropperButton> {
  // Hover lives in a notifier, NOT setState: setState would rebuild the [Tooltip]
  // (an OverlayPortal) on every enter/exit, and a hover-in-then-out double-
  // schedules its layout callback within one frame -> the object.dart
  // `scheduleLayoutCallback` assertion. Driving only a leaf
  // [ValueListenableBuilder] repaints the swatch while the Tooltip is built once.
  final _hover = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _hover.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Pick a colour from the screen',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => _hover.value = true,
        onExit: (_) => _hover.value = false,
        child: GestureDetector(
          onTap: widget.onTap,
          child: ValueListenableBuilder<bool>(
            valueListenable: _hover,
            builder: (_, hover, _) => Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: hover ? Colors.white12 : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: hover ? Colors.white54 : Colors.white24,
                ),
              ),
              child: Icon(
                Icons.colorize,
                size: 18,
                color: hover ? Colors.white : Colors.white70,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A horizontal gradient track with a round knob. [value] is 0..1.
/// [checkerboard] draws a checkerboard pattern behind the gradient
/// (used for the alpha slider to show transparency).
class _GradientSlider extends StatelessWidget {
  const _GradientSlider({
    required this.value,
    required this.gradient,
    required this.onChanged,
    required this.onCommit,
    this.checkerboard = false,
  });

  final double value;
  final LinearGradient gradient;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onCommit;
  final bool checkerboard;

  static const double _h = 22;
  static const double _knobSize = 18;
  static const double _trackH = 10;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _h,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          void update(double dx) {
            final v = (dx / w).clamp(0.0, 1.0);
            onChanged(v);
          }

          void end(double dx) {
            final v = (dx / w).clamp(0.0, 1.0);
            onCommit(v);
          }

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => update(d.localPosition.dx),
            onTapUp: (d) => end(d.localPosition.dx),
            onHorizontalDragUpdate: (d) => update(d.localPosition.dx),
            onHorizontalDragEnd: (d) {
              // Use last known position via value
              onCommit(value);
            },
            child: CustomPaint(
              size: Size(w, _h),
              painter: _GradientSliderPainter(
                value: value,
                gradient: gradient,
                checkerboard: checkerboard,
                trackHeight: _trackH,
                knobSize: _knobSize,
              ),
            ),
          );
        },
      ),
    );
  }
}

class _GradientSliderPainter extends CustomPainter {
  const _GradientSliderPainter({
    required this.value,
    required this.gradient,
    required this.checkerboard,
    required this.trackHeight,
    required this.knobSize,
  });

  final double value;
  final LinearGradient gradient;
  final bool checkerboard;
  final double trackHeight;
  final double knobSize;

  @override
  void paint(Canvas canvas, Size size) {
    final trackTop = (size.height - trackHeight) / 2;
    final trackRect = Rect.fromLTWH(0, trackTop, size.width, trackHeight);
    final rrect = RRect.fromRectAndRadius(
      trackRect,
      Radius.circular(trackHeight / 2),
    );

    // Draw checkerboard behind alpha slider
    if (checkerboard) {
      _paintCheckerboard(canvas, rrect, trackRect);
    }

    // Draw gradient track
    canvas.drawRRect(rrect, Paint()..shader = gradient.createShader(trackRect));

    // Draw knob
    final knobX = value * size.width;
    final knobCenter = Offset(
      knobX.clamp(knobSize / 2, size.width - knobSize / 2),
      size.height / 2,
    );
    final shadowPaint = Paint()..color = const Color(0x4D000000);
    canvas.drawCircle(knobCenter, knobSize / 2 + 1, shadowPaint);
    canvas.drawCircle(
      knobCenter,
      knobSize / 2,
      Paint()..color = const Color(0xFFFFFFFF),
    );
  }

  void _paintCheckerboard(Canvas canvas, RRect rrect, Rect trackRect) {
    canvas.save();
    canvas.clipRRect(rrect);
    const cellSize = 5.0;
    final cols = (trackRect.width / cellSize).ceil() + 1;
    final rows = (trackRect.height / cellSize).ceil() + 1;
    final light = Paint()..color = const Color(0xFFFFFFFF);
    final dark = Paint()..color = const Color(0xFFCBCBCB);
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < cols; c++) {
        final paint = (r + c).isEven ? light : dark;
        canvas.drawRect(
          Rect.fromLTWH(
            trackRect.left + c * cellSize,
            trackRect.top + r * cellSize,
            cellSize,
            cellSize,
          ),
          paint,
        );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GradientSliderPainter old) =>
      old.value != value ||
      old.gradient != gradient ||
      old.checkerboard != checkerboard;
}

// ---------------------------------------------------------------------------
// FontPickerPopover
// ---------------------------------------------------------------------------

/// A font-family picker popover with a search field and scrollable preview list.
///
/// [families] is injected by the host (fetched from FontBridge); this widget
/// is therefore fully testable without a native channel.
///
/// Each family row renders the name in its own font via
/// `TextStyle(fontFamily: name)` for a live preview.
///
/// A pinned "System" row at the top lets the user revert to the default font;
/// tapping it calls `onSelected(null)`.
class FontPickerPopover extends StatefulWidget {
  const FontPickerPopover({
    Key? key,
    required this.families,
    required this.selected,
    required this.onSelected,
  }) : super(key: key);

  /// All available font families (injected by the host).
  final List<String> families;

  /// Currently selected family, or null for System (default).
  final String? selected;

  /// Called with null when "System" is chosen, or the family name otherwise.
  final ValueChanged<String?> onSelected;

  @override
  State<FontPickerPopover> createState() => _FontPickerPopoverState();
}

class _FontPickerPopoverState extends State<FontPickerPopover> {
  late TextEditingController _searchCtrl;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchCtrl = TextEditingController();
    _searchCtrl.addListener(() {
      setState(() => _query = _searchCtrl.text);
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  List<String> get _filtered {
    if (_query.isEmpty) return widget.families;
    final q = _query.toLowerCase();
    return widget.families.where((f) => f.toLowerCase().contains(q)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    // Resolve foreground colours from the system appearance, mirroring the
    // toolbar's brightness-aware palette so the list reads on the glass in both
    // themes (the popover lives in an overlay, outside the toolbar's theme).
    final dark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final fg = dark ? Colors.white : const Color(0xFF14223B);
    final fgDim = dark ? Colors.white54 : const Color(0xFF64748B);
    final border = dark ? Colors.white24 : Colors.black26;
    const accent = GlimprTokens.accent;
    return SizedBox(
      width: 260,
      height: 380,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: TextField(
              key: const ValueKey('font-search'),
              controller: _searchCtrl,
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
                border: OutlineInputBorder(
                  borderSide: BorderSide(color: border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: fgDim),
                ),
                hintText: 'Search fonts…',
                hintStyle: TextStyle(color: fgDim, fontSize: 13),
              ),
              cursorColor: fg,
              style: TextStyle(fontSize: 13, color: fg),
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                // System row — always visible, not affected by search filter
                _FontRow(
                  key: const ValueKey('font-system'),
                  name: 'System',
                  fontFamily: null,
                  selected: widget.selected == null,
                  onTap: () => widget.onSelected(null),
                  color: fg,
                  accent: accent,
                ),
                Divider(height: 1, thickness: 1, color: border),
                ...filtered.map(
                  (name) => _FontRow(
                    key: ValueKey('font-$name'),
                    name: name,
                    fontFamily: name,
                    selected: widget.selected == name,
                    onTap: () => widget.onSelected(name),
                    color: fg,
                    accent: accent,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FontRow extends StatelessWidget {
  const _FontRow({
    Key? key,
    required this.name,
    required this.fontFamily,
    required this.selected,
    required this.onTap,
    required this.color,
    required this.accent,
  }) : super(key: key);

  final String name;
  final String? fontFamily;
  final bool selected;
  final VoidCallback onTap;
  final Color color; // resolved foreground (brightness-aware)
  final Color accent; // brand accent for the selected row + check

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          children: [
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: fontFamily,
                  fontSize: 14,
                  color: selected ? accent : color,
                ),
              ),
            ),
            if (selected) Icon(Icons.check, size: 16, color: accent),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// TexturePickerPopover (highlighter brush texture)
// ---------------------------------------------------------------------------

/// Human label for a highlighter [HighlighterTexture].
String textureLabel(HighlighterTexture t) => switch (t) {
  HighlighterTexture.clean => 'Clean',
  HighlighterTexture.streaks => 'Streaks',
  HighlighterTexture.frayed => 'Frayed',
};

/// A small menu listing the highlighter brush textures by name, each with a
/// readable preview rendered in [color]. Tapping a row calls [onSelected].
class TexturePickerPopover extends StatelessWidget {
  const TexturePickerPopover({
    Key? key,
    required this.selected,
    required this.color,
    required this.onSelected,
  }) : super(key: key);

  final HighlighterTexture selected;
  final Color color;
  final ValueChanged<HighlighterTexture> onSelected;

  @override
  Widget build(BuildContext context) {
    final dark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final fg = dark ? Colors.white : const Color(0xFF14223B);
    const accent = GlimprTokens.accent;
    // Fixed width so the rows' Expanded resolves and the check stays INSIDE the
    // panel (an unbounded width let the check overflow past the rounded border).
    return SizedBox(
      width: double.infinity,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final tex in HighlighterTexture.values)
            InkWell(
              onTap: () => onSelected(tex),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      // Clip the texture into a uniform rounded pill so every
                      // row's highlight has the SAME left/right bounds and never
                      // pokes past the panel corners — Clean's round cap and
                      // Frayed's end streaks would otherwise overflow the band.
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(5),
                        child: SizedBox(
                          height: 30,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              // The texture AS A HIGHLIGHT over the dark menu —
                              // translucent yellow on white was invisible; over
                              // the dark row it reads, like highlighting the word.
                              CustomPaint(painter: _TexturePreview(tex, color)),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                                child: Align(
                                  alignment: Alignment.center,
                                  child: Text(
                                    textureLabel(tex),
                                    style: TextStyle(
                                      color: tex == selected ? accent : fg,
                                      fontSize: 14,
                                      fontWeight: tex == selected
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    // Fixed check column so bands align and the check stays
                    // inside the panel.
                    SizedBox(
                      width: 22,
                      child: tex == selected
                          ? const Icon(Icons.check, size: 16, color: accent)
                          : null,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _TexturePreview extends CustomPainter {
  final HighlighterTexture texture;
  final Color color;
  _TexturePreview(this.texture, this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final stroke = (size.height * 0.72) / 5; // band ≈ 72% tall
    // Inset the band so the round cap / fray ends sit INSIDE the row (with a
    // margin), not cut flat at the clip edge.
    const inset = 16.0;
    paintHighlighterStroke(
      canvas,
      [Offset(inset, cy), Offset(size.width - inset, cy)],
      DrawStyle(color: color, strokeWidth: stroke, texture: texture),
    );
  }

  @override
  bool shouldRepaint(_TexturePreview old) =>
      old.texture != texture || old.color != color;
}

// ---------------------------------------------------------------------------
// _Swatch
// ---------------------------------------------------------------------------

/// A small square colour swatch with an optional selection ring.
class _Swatch extends StatelessWidget {
  const _Swatch({required this.color, required this.selected});
  final Color color;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(
          color: selected ? const Color(0xFF007AFF) : const Color(0x40000000),
          width: selected ? 2 : 1,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// LineStylePickerPopover  (line / arrow / highlighter)
// ---------------------------------------------------------------------------

String lineStyleLabel(LineStyle s) => switch (s) {
      LineStyle.solid => 'Solid',
      LineStyle.dashed => 'Dashed',
      LineStyle.dotted => 'Dotted',
      LineStyle.longDash => 'Long dash',
      LineStyle.dashDot => 'Dash-dot',
      LineStyle.dashDotDot => 'Dash-dot-dot',
    };

/// A menu of the six line styles, each with a live preview of the dash pattern.
class LineStylePickerPopover extends StatelessWidget {
  const LineStylePickerPopover({
    Key? key,
    required this.selected,
    required this.color,
    required this.onSelected,
  }) : super(key: key);

  final LineStyle selected;
  final Color color;
  final ValueChanged<LineStyle> onSelected;

  @override
  Widget build(BuildContext context) {
    final dark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final fg = dark ? Colors.white : const Color(0xFF14223B);
    const accent = GlimprTokens.accent;
    return SizedBox(
      width: double.infinity,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final s in LineStyle.values)
            InkWell(
              onTap: () => onSelected(s),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Row(
                  children: [
                    SizedBox(
                      width: 116,
                      child: Text(
                        lineStyleLabel(s),
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.visible,
                        style: TextStyle(
                          color: s == selected ? accent : fg,
                          fontSize: 13,
                          fontWeight:
                              s == selected ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                    ),
                    Expanded(
                      child: SizedBox(
                        height: 16,
                        child: CustomPaint(painter: _LineStylePreview(s, fg)),
                      ),
                    ),
                    SizedBox(
                      width: 22,
                      child: s == selected
                          ? const Icon(Icons.check, size: 16, color: accent)
                          : null,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _LineStylePreview extends CustomPainter {
  final LineStyle style;
  final Color color;
  const _LineStylePreview(this.style, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final path = Path()
      ..moveTo(2, y)
      ..lineTo(size.width - 2, y);
    final paint = Paint()
      ..color = color
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;
    drawStyledPath(canvas, path, paint, style, 3);
  }

  @override
  bool shouldRepaint(_LineStylePreview old) =>
      old.style != style || old.color != color;
}

// ---------------------------------------------------------------------------
// ArrowHeadsPickerPopover  (arrow only)
// ---------------------------------------------------------------------------

String arrowHeadsLabel(ArrowHeads h) => switch (h) {
      ArrowHeads.end => 'End',
      ArrowHeads.start => 'Start',
      ArrowHeads.both => 'Both',
    };

/// A small menu choosing which ends of the arrow carry a head.
class ArrowHeadsPickerPopover extends StatelessWidget {
  const ArrowHeadsPickerPopover({
    Key? key,
    required this.selected,
    required this.onSelected,
  }) : super(key: key);

  final ArrowHeads selected;
  final ValueChanged<ArrowHeads> onSelected;

  @override
  Widget build(BuildContext context) {
    final dark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final fg = dark ? Colors.white : const Color(0xFF14223B);
    const accent = GlimprTokens.accent;
    return SizedBox(
      width: double.infinity,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final h in ArrowHeads.values)
            InkWell(
              onTap: () => onSelected(h),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        arrowHeadsLabel(h),
                        style: TextStyle(
                          color: h == selected ? accent : fg,
                          fontSize: 14,
                          fontWeight:
                              h == selected ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 22,
                      child: h == selected
                          ? const Icon(Icons.check, size: 16, color: accent)
                          : null,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// RadiusPickerPopover  (rectangle corner radius)
// ---------------------------------------------------------------------------

/// Pill label for the option bar: "Auto" for the legacy size-relative radius,
/// else the explicit pixel value.
String radiusLabel(double r) => r < 0 ? 'Auto' : '${r.round()} px';

/// Corner-radius picker: the design-system [GlimprSlider] for an explicit radius
/// plus a labeled [GlassToggle] for "Auto" (the legacy size-relative radius, the
/// default). Opened from the option bar's "Radius" pill, so "Auto" has a clear
/// home instead of floating beside an anonymous stepper.
class RadiusPickerPopover extends StatelessWidget {
  const RadiusPickerPopover({
    Key? key,
    required this.value, // kCornerRadiusAuto (-1) or an explicit radius
    required this.max,
    required this.onChanged,
    required this.onAuto,
  }) : super(key: key);

  final double value;
  final double max;
  final ValueChanged<double> onChanged;
  final VoidCallback onAuto;

  @override
  Widget build(BuildContext context) {
    final dark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final tokens = dark ? GlimprTokens.dark : GlimprTokens.light;
    final isAuto = value < 0;
    // The capture overlay has no GlimprTheme ancestor (only the image editor /
    // settings provide one), yet the design-system slider/toggle read it via
    // GlimprTheme.of — so provide it here. Harmless where one already exists.
    return GlimprTheme(
      tokens: tokens,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Corner radius',
              style: GlimprType.sansStyle(13.5, 600, tokens.fg1),
            ),
            // The explicit slider only shows when Auto is off; Auto's own meaning
            // is always explained by the sub-line below, so an off->on switch is
            // never a mystery.
            if (!isAuto) ...[
              const SizedBox(height: 12),
              GlimprSlider(
                value: value.clamp(0.0, max),
                min: 0,
                max: max,
                onChanged: onChanged,
                suffix: 'px',
              ),
            ],
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Auto',
                        style: GlimprType.sansStyle(13.5, 600, tokens.fg2),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        "Radius scales with the rectangle's size",
                        style:
                            GlimprType.sansStyle(12, 400, tokens.fg3, height: 1.3),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                // On -> auto radius; off -> seed an explicit baseline so the
                // slider has a sensible starting value.
                GlassToggle(
                  value: isAuto,
                  onChanged: (on) =>
                      on ? onAuto() : onChanged(kCornerRadiusBaseline),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
