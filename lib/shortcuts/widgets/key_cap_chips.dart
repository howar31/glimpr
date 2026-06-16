import 'package:flutter/material.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theme/glimpr_theme.dart';
import '../hotkey_binding.dart';

/// One key cap, styled per the Aurora design (26x26, radius 7, 13px/600).
class KeyCap extends StatelessWidget {
  const KeyCap(this.label, {super.key});
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = GlimprTheme.of(context);
    final dark = t.brightness == Brightness.dark;
    return Container(
      constraints: const BoxConstraints(minWidth: 26),
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: dark
            ? const Color.fromRGBO(255, 255, 255, 0.07)
            : const Color.fromRGBO(255, 255, 255, 0.9),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(
          color: dark
              ? const Color.fromRGBO(255, 255, 255, 0.14)
              : const Color.fromRGBO(15, 23, 42, 0.14),
        ),
        boxShadow: [
          BoxShadow(
            color: dark
                ? const Color.fromRGBO(0, 0, 0, 0.4)
                : const Color.fromRGBO(15, 23, 42, 0.12),
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w600, color: t.fg1)),
    );
  }
}

/// A small muted pill naming the surface a shortcut applies to (Global / Editor
/// / Overlay / Image / Text). Informational only, and deliberately borderless so
/// it never reads as a recordable key cap. [width], when set, fixes the pill to
/// a shared width (the widest label) and centres the text, so every chip on a
/// page lines up regardless of label length.
class ScopeTag extends StatelessWidget {
  const ScopeTag(this.label, {super.key, this.width});
  final String label;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final t = GlimprTheme.of(context);
    final dark = t.brightness == Brightness.dark;
    return Container(
      width: width,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        color: dark
            ? const Color.fromRGBO(255, 255, 255, 0.06)
            : const Color.fromRGBO(15, 23, 42, 0.05),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: GlimprType.sansStyle(10.5, 600, t.fg3, letterSpacing: 0.2),
      ),
    );
  }
}

/// Renders a binding as a row of key caps (modifiers in canonical order + key),
/// or [emptyLabel] when the binding is null/unbound.
class KeyCapChips extends StatelessWidget {
  const KeyCapChips(this.binding, {super.key, this.emptyLabel});
  final HotkeyBinding? binding;
  // Null = the localized default ("None").
  final String? emptyLabel;

  @override
  Widget build(BuildContext context) {
    final b = binding;
    if (b == null) {
      // No cap when unbound — a bordered chip reads as "press me". Plain muted
      // text reads as "no shortcut" instead.
      final t = GlimprTheme.of(context);
      return Text(emptyLabel ?? AppLocalizations.of(context).keyCapNone,
          style: GlimprType.sansStyle(12.5, 600, t.fg4));
    }
    final platform = Theme.of(context).platform;
    final caps = <Widget>[
      for (final m in b.orderedModifiers)
        KeyCap(_modSymbol(m, platform == TargetPlatform.macOS)),
      KeyCap(keyLabelOf(b.logicalKey)),
    ];
    return Wrap(spacing: 5, children: caps);
  }
}

String _modSymbol(HotkeyModifier m, bool mac) => switch (m) {
      HotkeyModifier.control => mac ? '⌃' : 'Ctrl',
      HotkeyModifier.alt => mac ? '⌥' : 'Alt',
      HotkeyModifier.shift => mac ? '⇧' : 'Shift',
      HotkeyModifier.meta => mac ? '⌘' : 'Win',
    };
