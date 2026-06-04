import 'package:flutter/material.dart';
import '../editor/color_math.dart';
import '../editor/draw_style.dart';

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
  }) : super(key: key);

  final Color color;

  /// MRU list of ARGB ints to show as recent swatches.
  final List<int> recents;

  /// Called on every live change (drag, tap preset, valid hex entry).
  final ValueChanged<Color> onChanged;

  /// Called when an interaction completes (drag end, tap, field submit).
  final ValueChanged<Color> onCommit;

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
      children: kColorPresets.map((c) {
        final argb = c.toARGB32();
        final keyStr =
            'preset-0x${argb.toRadixString(16).toUpperCase()}';
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
      gradient: const LinearGradient(colors: [
        Color(0xFFFF0000),
        Color(0xFFFFFF00),
        Color(0xFF00FF00),
        Color(0xFF00FFFF),
        Color(0xFF0000FF),
        Color(0xFFFF00FF),
        Color(0xFFFF0000),
      ]),
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
      gradient: LinearGradient(colors: [
        const Color(0x00000000),
        opaque,
      ]),
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
    return TextField(
      key: const ValueKey('hex-field'),
      controller: _hexCtrl,
      decoration: const InputDecoration(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        border: OutlineInputBorder(),
        hintText: '#RRGGBB or #AARRGGBB',
      ),
      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
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
          child: CustomPaint(
            size: size,
            painter: _SVPlanePainter(hsv),
          ),
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
    final rrect =
        RRect.fromRectAndRadius(trackRect, Radius.circular(trackHeight / 2));

    // Draw checkerboard behind alpha slider
    if (checkerboard) {
      _paintCheckerboard(canvas, rrect, trackRect);
    }

    // Draw gradient track
    canvas.drawRRect(
      rrect,
      Paint()..shader = gradient.createShader(trackRect),
    );

    // Draw knob
    final knobX = value * size.width;
    final knobCenter = Offset(knobX.clamp(knobSize / 2, size.width - knobSize / 2), size.height / 2);
    final shadowPaint = Paint()..color = const Color(0x4D000000);
    canvas.drawCircle(knobCenter, knobSize / 2 + 1, shadowPaint);
    canvas.drawCircle(knobCenter, knobSize / 2, Paint()..color = const Color(0xFFFFFFFF));
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
          color: selected
              ? const Color(0xFF007AFF)
              : const Color(0x40000000),
          width: selected ? 2 : 1,
        ),
      ),
    );
  }
}
