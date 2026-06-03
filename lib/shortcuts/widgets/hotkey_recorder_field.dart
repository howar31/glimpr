import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../theme/glimpr_theme.dart';
import '../hotkey_binding.dart';
import 'key_cap_chips.dart';

/// Click to record a combo, then press the desired key chord. [requireModifier]
/// rejects modifier-less combos (Tier 1, the global capture hotkey).
/// [reservedKeys] rejects fixed editor keys (Esc / arrows). Esc cancels
/// recording (keeps the prior value); clicking anywhere else also cancels.
///
/// Clearing a binding is the row's job (a visible ✕ button), NOT a key — so every
/// other key, including Backspace, is freely recordable. The field is a FIXED
/// height and shows its prompt / error message inline, so changing state never
/// reflows the surrounding rows.
class HotkeyRecorderField extends StatefulWidget {
  const HotkeyRecorderField({
    super.key,
    required this.value,
    required this.onChanged,
    required this.requireModifier,
    this.reservedKeys = const {},
    this.emptyLabel = 'Disabled',
  });

  final HotkeyBinding? value;
  final ValueChanged<HotkeyBinding?> onChanged;
  final bool requireModifier;
  final Set<LogicalKeyboardKey> reservedKeys;

  /// Shown (as muted text, not a cap) when [value] is null — e.g. "Disabled" for
  /// the global hotkey, "None" for an editor tool with no shortcut.
  final String emptyLabel;

  @override
  State<HotkeyRecorderField> createState() => _HotkeyRecorderFieldState();
}

class _HotkeyRecorderFieldState extends State<HotkeyRecorderField> {
  // 26px content (a key cap) + 8px above and below = 8px all round, matching the
  // 8px horizontal padding so the box is evenly inset on every side.
  static const double _fieldHeight = 42;

  final _focus = FocusNode();
  bool _recording = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(HotkeyRecorderField old) {
    super.didUpdateWidget(old);
    // An external change (the row's Clear / Reset button) supersedes an
    // in-progress recording — drop back to showing the new value.
    if (_recording && widget.value != old.value) {
      setState(() {
        _recording = false;
        _error = null;
      });
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    super.dispose();
  }

  // Clicking anywhere else (another row, the Clear/Reset buttons, the sidebar)
  // cancels recording so the field never stays stuck on "Press keys…".
  void _onFocusChange() {
    if (!_focus.hasFocus && _recording) {
      setState(() {
        _recording = false;
        _error = null;
      });
    }
  }

  void _start() {
    setState(() {
      _recording = true;
      _error = null;
    });
    _focus.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (!_recording || e is! KeyDownEvent) return KeyEventResult.ignored;
    final key = e.logicalKey;
    _error = null; // re-evaluate fresh on each keystroke

    if (key == LogicalKeyboardKey.escape) {
      setState(() => _recording = false); // cancel: keep prior value
      return KeyEventResult.handled;
    }
    if (_isModifierKey(key)) return KeyEventResult.handled; // wait for a main key
    if (widget.reservedKeys.contains(key)) {
      setState(() => _error = 'Reserved key');
      return KeyEventResult.handled;
    }

    final pressed = <HotkeyModifier>{
      if (HardwareKeyboard.instance.isMetaPressed) HotkeyModifier.meta,
      if (HardwareKeyboard.instance.isAltPressed) HotkeyModifier.alt,
      if (HardwareKeyboard.instance.isControlPressed) HotkeyModifier.control,
      if (HardwareKeyboard.instance.isShiftPressed) HotkeyModifier.shift,
    };
    if (widget.requireModifier && pressed.isEmpty) {
      setState(() => _error = 'Needs a modifier (⌘ ⌥ ⌃ ⇧)');
      return KeyEventResult.handled;
    }
    widget.onChanged(HotkeyBinding(
      physicalKey: e.physicalKey,
      logicalKey: key,
      modifiers: pressed,
    ));
    setState(() {
      _recording = false;
      _error = null;
    });
    return KeyEventResult.handled;
  }

  // The field's fixed trailing slot is contextual: when idle it is a keyboard
  // glyph (= "click here to record"); while recording it becomes a ✕ (= "click
  // to clear / disable this binding"). Clear is therefore reachable only through
  // recording — there is no outside clear button — and the always-present slot
  // never shifts the row left/right.
  Widget _trailingIcon(GlimprTokens t) {
    if (!_recording) {
      return Icon(Icons.keyboard_outlined, size: 15, color: t.fg3);
    }
    return Tooltip(
      message: 'Clear',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          widget.onChanged(null); // clear → unbound (disabled)
          setState(() {
            _recording = false;
            _error = null;
          });
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Icon(Icons.close, size: 15, color: t.fg2),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = GlimprTheme.of(context);
    final hasError = _error != null;
    final borderColor = hasError
        ? GlimprTokens.danger
        : (_recording ? GlimprTokens.accent : t.fieldBorder);

    // Everything renders inside the fixed-height box (no separate hint line), so
    // the prompt / error never changes the field's — or the row's — height. The
    // always-present trailing slot flips keyboard↔✕ by state (see _trailingIcon),
    // so no element comes/goes to shift the row.
    final Widget primary = _recording
        ? Text(
            _error ?? 'Press keys…',
            style: GlimprType.sansStyle(
                12.5, 600, hasError ? GlimprTokens.danger : t.fg2),
          )
        : KeyCapChips(widget.value, emptyLabel: widget.emptyLabel);
    final Widget content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        primary,
        const SizedBox(width: 8),
        _trailingIcon(t),
      ],
    );

    Widget field = Container(
      height: _fieldHeight,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: t.fieldBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: borderColor,
          width: (_recording || hasError) ? 1.5 : 1,
        ),
      ),
      child: content,
    );
    if (_recording) {
      // Hovering the record area while recording explains the cancel key. The
      // trailing ✕ keeps its own "Clear" tooltip (wins on its own region).
      field = Tooltip(message: 'Press Esc to cancel', child: field);
    }
    return Focus(
      focusNode: _focus,
      onKeyEvent: _onKey,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _start,
          child: field,
        ),
      ),
    );
  }
}

// LogicalKeyboardKey has no primitive equality, so this cannot be a const set
// (mirrors kEditorReservedKeys in shortcut_actions.dart). Includes the generic
// meta/alt/control/shift keys as well as their Left/Right variants, since the
// test framework's sendKeyDownEvent emits the generic logical key.
final _modifierKeys = <LogicalKeyboardKey>{
  LogicalKeyboardKey.meta,
  LogicalKeyboardKey.metaLeft,
  LogicalKeyboardKey.metaRight,
  LogicalKeyboardKey.alt,
  LogicalKeyboardKey.altLeft,
  LogicalKeyboardKey.altRight,
  LogicalKeyboardKey.control,
  LogicalKeyboardKey.controlLeft,
  LogicalKeyboardKey.controlRight,
  LogicalKeyboardKey.shift,
  LogicalKeyboardKey.shiftLeft,
  LogicalKeyboardKey.shiftRight,
};

bool _isModifierKey(LogicalKeyboardKey k) => _modifierKeys.contains(k);
