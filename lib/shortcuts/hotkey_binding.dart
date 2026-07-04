import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Our platform-neutral modifier set (omits capsLock + fn, which are not used
/// for shortcuts). `meta` = Command on macOS / Win key on Windows (mapped
/// per-platform by the registrar + label).
enum HotkeyModifier { meta, alt, control, shift }

/// A key combination. Stores BOTH key representations because the two tiers need
/// different ones: Tier 1 (global) registers by PHYSICAL key (position-based,
/// layout-independent, mapped to a native keycode by the registrar); Tier 2
/// (editor) matches by LOGICAL key (the existing _onKey behavior) and uses it
/// for the display label.
@immutable
class HotkeyBinding {
  const HotkeyBinding({
    required this.physicalKey,
    required this.logicalKey,
    required this.modifiers,
  });

  final PhysicalKeyboardKey physicalKey;
  final LogicalKeyboardKey logicalKey;
  final Set<HotkeyModifier> modifiers;

  Map<String, dynamic> toJson() => {
        'phys': physicalKey.usbHidUsage,
        'logi': logicalKey.keyId,
        'mods': modifiers.map((m) => m.name).toList(),
      };

  /// Returns null if the stored ids do not resolve to real keys (corrupt /
  /// version-drift) — the caller then falls back to the action's default.
  static HotkeyBinding? fromJson(Map<String, dynamic> json) {
    final phys = PhysicalKeyboardKey.findKeyByCode(json['phys'] as int);
    final logi = LogicalKeyboardKey.findKeyByKeyId(json['logi'] as int);
    if (phys == null || logi == null) return null;
    final mods = <HotkeyModifier>{};
    for (final name in (json['mods'] as List).cast<String>()) {
      final m = HotkeyModifier.values.where((e) => e.name == name);
      if (m.isNotEmpty) mods.add(m.first); // unknown names dropped (forward-compat)
    }
    return HotkeyBinding(physicalKey: phys, logicalKey: logi, modifiers: mods);
  }

  /// Tier-2 only: exact match against a key event + the currently-pressed
  /// modifier set. Exact modifier equality means bare-C never matches Cmd-C.
  bool matches(KeyEvent e, Set<HotkeyModifier> pressed) =>
      e.logicalKey == logicalKey && _setEquals(pressed, modifiers);

  /// Display string, e.g. "⌘⌥1" on macOS. Modifiers in canonical order.
  String label([TargetPlatform? platform]) {
    final p = platform ?? defaultTargetPlatform;
    final sb = StringBuffer();
    for (final m in _canonicalOrder) {
      if (modifiers.contains(m)) sb.write(_modifierSymbol(m, p));
    }
    sb.write(_keyLabel(logicalKey));
    return sb.toString();
  }

  /// Modifiers in canonical macOS display order then key (used by chips too).
  List<HotkeyModifier> get orderedModifiers =>
      _canonicalOrder.where(modifiers.contains).toList();

  @override
  bool operator ==(Object other) =>
      other is HotkeyBinding &&
      other.physicalKey == physicalKey &&
      other.logicalKey == logicalKey &&
      _setEquals(other.modifiers, modifiers);

  @override
  int get hashCode => Object.hash(
        physicalKey,
        logicalKey,
        Object.hashAllUnordered(modifiers),
      );
}

const _canonicalOrder = [
  HotkeyModifier.control,
  HotkeyModifier.alt,
  HotkeyModifier.shift,
  HotkeyModifier.meta,
];

String _modifierSymbol(HotkeyModifier m, TargetPlatform p) {
  final mac = p == TargetPlatform.macOS;
  return switch (m) {
    HotkeyModifier.control => mac ? '⌃' : 'Ctrl+',
    HotkeyModifier.alt => mac ? '⌥' : 'Alt+',
    HotkeyModifier.shift => mac ? '⇧' : 'Shift+',
    HotkeyModifier.meta => mac ? '⌘' : 'Win+',
  };
}

/// Friendly single-token label for the main key (chips show one cap per token).
String keyLabelOf(LogicalKeyboardKey k) => _keyLabel(k);
String _keyLabel(LogicalKeyboardKey k) {
  // Keys are matched by their real LogicalKeyboardKey.keyId values.
  const special = {
    0x10000000d: '⏎', // enter (U+23CE return symbol — monochrome, not emoji)
    0x20000020d: '⏎', // numpad enter
    0x10000001b: 'esc', // escape
    0x100000008: '⌫', // backspace
    0x10000007f: 'Del', // delete (forward)
    0x100000302: '←', // arrowLeft
    0x100000303: '→', // arrowRight
    0x100000304: '↑', // arrowUp
    0x100000301: '↓', // arrowDown
    0x100000009: '⇥', // tab
    0x20: 'Space', // space
  };
  return special[k.keyId] ?? (k.keyLabel.isNotEmpty ? k.keyLabel : 'Key');
}

bool _setEquals(Set<HotkeyModifier> a, Set<HotkeyModifier> b) =>
    a.length == b.length && a.containsAll(b);
