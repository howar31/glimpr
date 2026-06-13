import 'dart:async' show Timer;
import 'package:flutter/widgets.dart';
import 'glimpr_theme.dart';

/// Design-system widgets for the Aurora settings theme, ported from the design
/// handoff's `components.jsx`. Each reads the active [GlimprTokens] via
/// [GlimprTheme.of], so the same widget renders correctly in light or dark.

/// The Glimpr brand gradient (cyan → blue → violet), 135° top-left → bottom-right.
/// Deliberately distinct from the Aurora UI accent ([GlimprTokens.accentGrad]) —
/// the logo keeps its own identity across surfaces.
const LinearGradient kGlimprLogoGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0xFF22D3EE), Color(0xFF3B82F6), Color(0xFFA78BFA)],
  stops: [0.0, 0.52, 1.0],
);

/// The Glimpr wordmark — the leading "G" carries the brand gradient, the rest is
/// solid foreground (white on dark, ink on light), per the locked logo spec.
class Wordmark extends StatelessWidget {
  const Wordmark({super.key, this.size = 19, this.restColor});
  final double size;

  /// Color of the "limpr" letters; defaults to the active foreground token.
  final Color? restColor;

  @override
  Widget build(BuildContext context) {
    final t = GlimprTheme.of(context);
    final style = GlimprType.displayStyle(
      size,
      800,
      restColor ?? t.fg1,
      letterSpacing: size * -0.035,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (r) => kGlimprLogoGradient.createShader(r),
          child: Text('G', style: style.copyWith(color: const Color(0xFFFFFFFF))),
        ),
        Text('limpr', style: style),
      ],
    );
  }
}

/// The Viewfinder mark — four crop brackets around a capture spark. Painted in
/// the brand gradient, or a solid [color] override. Drawn on the 96-unit design
/// grid, framed to the content box (grid 12..84) so it fills [size] like the
/// monochrome menu-bar asset.
class GlimprMark extends StatelessWidget {
  const GlimprMark({super.key, this.size = 26, this.color});
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _MarkPainter(color));
}

/// Paints the Viewfinder mark (brackets + spark) into [canvas] at [size].
/// Shared by [GlimprMark] and any offscreen renderer (e.g. the loupe preview).
/// [color] flattens it to a single colour; null uses the brand logo gradient.
void paintGlimprMark(Canvas canvas, Size size, {Color? color}) {
  final s = size.width / 72.0;
  canvas.save();
  canvas.translate(-12 * s, -12 * s);
  canvas.scale(s);

  final brackets = Path()
    ..moveTo(36, 18)
    ..lineTo(23, 18)
    ..arcToPoint(const Offset(18, 23),
        radius: const Radius.circular(5), clockwise: false)
    ..lineTo(18, 36)
    ..moveTo(60, 18)
    ..lineTo(73, 18)
    ..arcToPoint(const Offset(78, 23),
        radius: const Radius.circular(5), clockwise: true)
    ..lineTo(78, 36)
    ..moveTo(78, 60)
    ..lineTo(78, 73)
    ..arcToPoint(const Offset(73, 78),
        radius: const Radius.circular(5), clockwise: true)
    ..lineTo(60, 78)
    ..moveTo(18, 60)
    ..lineTo(18, 73)
    ..arcToPoint(const Offset(23, 78),
        radius: const Radius.circular(5), clockwise: false)
    ..lineTo(36, 78);

  final spark = Path()
    ..moveTo(48, 31)
    ..cubicTo(49.7, 43, 53, 46.3, 65, 48)
    ..cubicTo(53, 49.7, 49.7, 53, 48, 65)
    ..cubicTo(46.3, 53, 43, 49.7, 31, 48)
    ..cubicTo(43, 46.3, 46.3, 43, 48, 31)
    ..close();

  const rect = Rect.fromLTRB(18, 18, 78, 78);
  final stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 8.5
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  final fill = Paint()..style = PaintingStyle.fill;
  if (color != null) {
    stroke.color = color;
    fill.color = color;
  } else {
    stroke.shader = kGlimprLogoGradient.createShader(rect);
    fill.shader = kGlimprLogoGradient.createShader(rect);
  }
  canvas.drawPath(brackets, stroke);
  canvas.drawPath(spark, fill);
  canvas.restore();
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.color);
  final Color? color;

  @override
  void paint(Canvas canvas, Size size) =>
      paintGlimprMark(canvas, size, color: color);

  @override
  bool shouldRepaint(_MarkPainter old) => old.color != color;
}

/// The full logo lockup — the Viewfinder mark beside the wordmark. Used in the
/// settings sidebar header.
class Lockup extends StatelessWidget {
  const Lockup({super.key, this.markSize = 25, this.fontSize = 21});
  final double markSize;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GlimprMark(size: markSize),
        SizedBox(width: markSize * 0.34),
        Wordmark(size: fontSize),
      ],
    );
  }
}

/// A sidebar navigation row (icon + label) with an active + hover state.
class NavItem extends StatefulWidget {
  const NavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  State<NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<NavItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = GlimprTheme.of(context);
    final fg = widget.active ? t.navActiveFg : t.fg2;
    final bg = widget.active
        ? t.navActiveBg
        : (_hover ? t.navHoverBg : const Color(0x00000000));
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 17, color: fg),
              const SizedBox(width: 11),
              // Flexible + ellipsis: a long pane title (or a wide test font)
              // must never overflow the fixed-width sidebar.
              Flexible(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GlimprType.sansStyle(14, 600, fg),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Uppercase eyebrow label, optionally led by an icon.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.label, {super.key, this.icon, this.note});
  final String label;
  final IconData? icon;

  /// Optional muted note shown after the label (normal case), e.g. a section-wide
  /// rule like "Needs a modifier".
  final String? note;

  @override
  Widget build(BuildContext context) {
    final t = GlimprTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: t.fg3),
            const SizedBox(width: 7),
          ],
          Text(
            label.toUpperCase(),
            style: GlimprType.sansStyle(11.5, 700, t.fg3, letterSpacing: 1.0),
          ),
          if (note != null) ...[
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                note!,
                overflow: TextOverflow.ellipsis,
                style: GlimprType.sansStyle(11.5, 400, t.fg4),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A glass card. Use [GlassCard.rows] for a list of setting rows separated by
/// hairline dividers, or [GlassCard.padded] for a single padded body.
class GlassCard extends StatelessWidget {
  const GlassCard.rows(this.rows, {super.key}) : pad = null, child = null;
  const GlassCard.padded({super.key, required this.child, this.pad = 18})
    : rows = null;

  final List<Widget>? rows;
  final Widget? child;
  final double? pad;

  @override
  Widget build(BuildContext context) {
    final t = GlimprTheme.of(context);
    final decoration = BoxDecoration(
      color: t.cardBg,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: t.cardBorder),
    );
    if (rows != null) {
      return Container(
        clipBehavior: Clip.antiAlias,
        decoration: decoration,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows!,
        ),
      );
    }
    return Container(
      decoration: decoration,
      padding: EdgeInsets.all(pad!),
      child: child,
    );
  }
}

/// A single setting line: title (+ hint) on the left, a control on the right.
/// [divider] draws a hairline separator above the row (used for stacked rows).
class SettingRow extends StatelessWidget {
  const SettingRow({
    super.key,
    required this.title,
    this.hint,
    required this.trailing,
    this.icon,
    this.iconWidget,
    this.divider = false,
    this.enabled = true,
  });

  final String title;
  final String? hint;
  final Widget trailing;
  final IconData? icon;

  /// Custom glyph rendered inside the standard 34x34 icon tile instead of
  /// [icon] (e.g. the Crop / Pin row's diagonal dual icon). The tile itself
  /// (size, fill, radius) is unchanged, so the title column stays aligned.
  final Widget? iconWidget;
  final bool divider;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final t = GlimprTheme.of(context);
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      child: Row(
        children: [
          if (icon != null || iconWidget != null) ...[
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: t.accentSoft,
                borderRadius: BorderRadius.circular(9),
              ),
              alignment: Alignment.center,
              child: iconWidget ?? Icon(icon, size: 18, color: t.accentFg),
            ),
            const SizedBox(width: 16),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GlimprType.sansStyle(
                    14.5,
                    600,
                    t.fg1,
                    letterSpacing: -0.145,
                  ),
                ),
                if (hint != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      hint!,
                      style: GlimprType.sansStyle(12.5, 400, t.fg3, height: 1.4),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          trailing,
        ],
      ),
    );
    final wrapped = enabled
        ? row
        : Opacity(
            opacity: 0.4,
            child: IgnorePointer(child: row),
          );
    if (!divider) return wrapped;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: t.divider)),
      ),
      child: wrapped,
    );
  }
}

/// Cyan→blue gradient toggle with a white knob.
class GlassToggle extends StatelessWidget {
  const GlassToggle({super.key, required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = GlimprTheme.of(context);
    const w = 48.0, h = 28.0, k = 22.0;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => onChanged(!value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          width: w,
          height: h,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            gradient: value ? GlimprTokens.accentGrad : null,
            color: value ? null : t.track,
            boxShadow: value
                ? [
                    BoxShadow(
                      color: t.shadowAccent,
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : null,
          ),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutBack,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: Container(
                width: k,
                height: k,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: t.knob,
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x47000000),
                      blurRadius: 5,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A pill segmented control. The selected segment fills with the accent
/// gradient. [full] stretches the segments to fill the available width.
class Segmented<T> extends StatelessWidget {
  const Segmented({
    super.key,
    required this.value,
    required this.onChanged,
    required this.options,
    this.full = false,
  });

  final T value;
  final ValueChanged<T> onChanged;
  final List<(T, String)> options;
  final bool full;

  @override
  Widget build(BuildContext context) {
    final t = GlimprTheme.of(context);
    Widget seg((T, String) o) {
      final active = o.$1 == value;
      final btn = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(o.$1),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            gradient: active ? GlimprTokens.accentGrad : null,
            boxShadow: active
                ? [
                    BoxShadow(
                      color: t.shadowAccent,
                      blurRadius: 14,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Text(
            o.$2,
            style: GlimprType.sansStyle(
              13,
              600,
              active ? GlimprTokens.onAccent : t.fg2,
            ),
          ),
        ),
      );
      return full
          ? Expanded(child: MouseRegion(cursor: SystemMouseCursors.click, child: btn))
          : MouseRegion(cursor: SystemMouseCursors.click, child: btn);
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: t.insetBg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: t.cardBorder),
      ),
      child: Row(
        mainAxisSize: full ? MainAxisSize.max : MainAxisSize.min,
        children: [
          for (var i = 0; i < options.length; i++) ...[
            if (i > 0) const SizedBox(width: 2),
            seg(options[i]),
          ],
        ],
      ),
    );
  }
}

/// Gradient-fill slider with a soft white knob and a monospace value readout.
class GlimprSlider extends StatelessWidget {
  const GlimprSlider({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.onChangeEnd,
    this.suffix = '',
  });

  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;
  final String suffix;

  @override
  Widget build(BuildContext context) {
    final t = GlimprTheme.of(context);
    final pct = ((value - min) / (max - min)).clamp(0.0, 1.0);
    return Row(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (ctx, c) {
              final w = c.maxWidth;
              void update(double dx) {
                final p = (dx / w).clamp(0.0, 1.0);
                onChanged(min + p * (max - min));
              }

              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) => update(d.localPosition.dx),
                onTapUp: (_) => onChangeEnd?.call(value),
                onHorizontalDragUpdate: (d) => update(d.localPosition.dx),
                onHorizontalDragEnd: (_) => onChangeEnd?.call(value),
                child: SizedBox(
                  height: 22,
                  child: Stack(
                    children: [
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 8.5,
                        height: 5,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: t.track,
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 0,
                        top: 8.5,
                        width: pct * w,
                        height: 5,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: GlimprTokens.accentGrad,
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                      Positioned(
                        left: (pct * w - 9).clamp(0.0, (w - 18).clamp(0.0, w)),
                        top: 2,
                        width: 18,
                        height: 18,
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: t.knob,
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x4D000000),
                                blurRadius: 6,
                                offset: Offset(0, 2),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(width: 14),
        SizedBox(
          width: 44,
          child: Text(
            '${value.round()}$suffix',
            textAlign: TextAlign.right,
            style: GlimprType.mono(13, t.fg2),
          ),
        ),
      ],
    );
  }
}

/// Primary (accent gradient) action button. On hover it brightens slightly —
/// the same no-movement highlight model as [GhostButton], so all buttons behave
/// consistently (no lift, no shadow ramp).
class AccentButton extends StatefulWidget {
  const AccentButton(this.label, {super.key, required this.onTap, this.icon});
  final String label;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  State<AccentButton> createState() => _AccentButtonState();
}

class _AccentButtonState extends State<AccentButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = GlimprTheme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          decoration: BoxDecoration(
            gradient: GlimprTokens.accentGrad,
            borderRadius: BorderRadius.circular(9),
            boxShadow: [
              BoxShadow(
                color: t.shadowAccent,
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          // A faint white wash to read as "brighter" on hover (no movement —
          // consistent with the ghost button).
          foregroundDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            color: _hover ? const Color(0x1FFFFFFF) : const Color(0x00FFFFFF),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 16, color: GlimprTokens.onAccent),
                const SizedBox(width: 7),
              ],
              Text(
                widget.label,
                style: GlimprType.sansStyle(13.5, 600, GlimprTokens.onAccent),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Quiet text button (ghost). Dims when [onTap] is null; on hover it picks up a
/// soft fill and a brighter label.
/// How long a two-step destructive confirm stays armed before it disarms
/// itself. SSOT for the app-wide confirm timeout; the native recording strip
/// mirrors this in RecordingDesign.confirmDisarmSeconds — keep the two in sync.
const kConfirmDisarmDuration = Duration(seconds: 3);

/// A [GhostButton] for destructive actions: the first click ARMS it (the label
/// flips to a danger-coloured [confirmLabel]), a second click within the window
/// fires [onConfirmed]; left untouched it disarms itself after a few seconds.
class ConfirmGhostButton extends StatefulWidget {
  const ConfirmGhostButton(
    this.label, {
    super.key,
    required this.confirmLabel,
    required this.onConfirmed,
  });
  final String label;
  final String confirmLabel;
  final VoidCallback? onConfirmed;

  @override
  State<ConfirmGhostButton> createState() => _ConfirmGhostButtonState();
}

class _ConfirmGhostButtonState extends State<ConfirmGhostButton> {
  bool _armed = false;
  Timer? _disarm;

  @override
  void dispose() {
    _disarm?.cancel();
    super.dispose();
  }

  void _tapped() {
    if (!_armed) {
      setState(() => _armed = true);
      _disarm?.cancel();
      _disarm = Timer(kConfirmDisarmDuration, () {
        if (mounted) setState(() => _armed = false);
      });
      return;
    }
    _disarm?.cancel();
    setState(() => _armed = false); // back to idle once the action fires
    widget.onConfirmed?.call();
  }

  @override
  Widget build(BuildContext context) => GhostButton(
        _armed ? widget.confirmLabel : widget.label,
        danger: _armed,
        onTap: widget.onConfirmed == null ? null : _tapped,
      );
}

class GhostButton extends StatefulWidget {
  const GhostButton(this.label, {super.key, required this.onTap, this.danger = false});
  final String label;
  final VoidCallback? onTap;

  /// Render the label in the danger colour — for an armed/confirm state of a
  /// destructive action (e.g. the Settings restart button).
  final bool danger;

  @override
  State<GhostButton> createState() => _GhostButtonState();
}

class _GhostButtonState extends State<GhostButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = GlimprTheme.of(context);
    final enabled = widget.onTap != null;
    final active = enabled && _hover;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: enabled ? (_) => setState(() => _hover = true) : null,
      onExit: enabled ? (_) => setState(() => _hover = false) : null,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            color: active ? t.navHoverBg : const Color(0x00000000),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(
            widget.label,
            style: GlimprType.sansStyle(
              13.5,
              600,
              widget.danger && enabled
                  ? GlimprTokens.danger
                  : !enabled
                      ? t.fg4
                      : (active ? t.fg2 : t.fg3),
            ),
          ),
        ),
      ),
    );
  }
}
