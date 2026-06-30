import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theme/glimpr_theme.dart';
import '../hotkey_binding.dart';
import '../hotkey_registrar.dart';
import '../windows_hotkey_codes.dart';
import 'key_cap_chips.dart';

/// Click to record a combo, then press the desired key chord. Any key combo is
/// recordable, with or without a modifier (a bare key — PrintScreen, an F-key —
/// is a valid global hotkey, ShareX-style). [isReserved] rejects a recorded
/// combo that collides with a fixed editor / system shortcut (the full key +
/// modifier set is passed, so it can reject ⌘W while allowing bare W). Esc
/// cancels recording (keeps the prior value); clicking anywhere else also cancels.
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
    this.isReserved,
    this.emptyLabel,
    this.onRecordingChanged,
    this.keyCapture,
    this.hasWarning = false,
  });

  /// The committed binding is invalid (a duplicate combo, or reserved / taken by
  /// another app). Paints the field's border red so the problem row stands out,
  /// not just the warning sub-line under it.
  final bool hasWarning;

  final HotkeyBinding? value;

  /// Fires when a combo is recorded (or cleared, with a null binding).
  /// [available] is false when a record-time probe found the combo reserved /
  /// already taken by another app (Windows only) — the Shortcuts pane then marks
  /// it + blocks Apply, like an internal duplicate. Always true on macOS / clear.
  final void Function(HotkeyBinding? binding, {bool available}) onChanged;

  /// Native key capture (Windows only): when non-null the recorder reads keys
  /// from the OS window-proc instead of Flutter events, so PrintScreen + the Win
  /// key (which Flutter drops) are recordable. Null on macOS -> Flutter events.
  final HotkeyKeyCapture? keyCapture;

  /// Returns true when binding the given key + modifiers would collide with a
  /// fixed editor / system shortcut, so the recorder refuses it.
  final bool Function(LogicalKeyboardKey key, Set<HotkeyModifier> modifiers)?
      isReserved;

  /// Fired when recording starts / stops. The Shortcuts pane uses it to SUSPEND
  /// the live global hotkeys while recording — otherwise a system-registered
  /// combo (e.g. ⌘⌥1) is swallowed by the OS + fires its action instead of
  /// being captured here.
  final ValueChanged<bool>? onRecordingChanged;

  /// Shown (as muted text, not a cap) when [value] is null — e.g. "Disabled" for
  /// the global hotkey, "None" for an editor tool with no shortcut. Null =
  /// the localized default ("Disabled").
  final String? emptyLabel;

  @override
  State<HotkeyRecorderField> createState() => _HotkeyRecorderFieldState();
}

class _HotkeyRecorderFieldState extends State<HotkeyRecorderField> {
  // 26px content (a key cap) + 8px above and below = 8px all round, matching the
  // 8px horizontal padding so the box is evenly inset on every side.
  static const double _fieldHeight = 42;

  final _focus = FocusNode();
  bool _recording = false;
  bool _lastNotifiedRecording = false;
  bool _nativeCapturing = false; // a native (Windows) capture session is active
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
      _stopCapture();
      setState(() {
        _recording = false;
        _error = null;
      });
    }
  }

  @override
  void dispose() {
    // Disposed mid-recording (e.g. switching tabs) — balance the notification so
    // the paused global hotkeys are resumed, and end any native capture.
    _stopCapture();
    if (_lastNotifiedRecording) widget.onRecordingChanged?.call(false);
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    super.dispose();
  }

  // Clicking anywhere else (another row, the Clear/Reset buttons, the sidebar)
  // cancels recording so the field never stays stuck on "Press keys…".
  void _onFocusChange() {
    if (!_focus.hasFocus && _recording) {
      _stopCapture();
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
    // Windows: keys come from the native window-proc capture (Flutter drops
    // PrintScreen + the Win key). macOS: keyCapture is null -> Flutter _onKey.
    final cap = widget.keyCapture;
    if (cap != null) {
      _nativeCapturing = true;
      cap.beginKeyCapture(_onNativeKey, _onNativeCancel);
    }
  }

  // End any native capture session (idempotent). Call wherever recording stops.
  void _stopCapture() {
    if (_nativeCapturing) {
      _nativeCapturing = false;
      widget.keyCapture?.endKeyCapture();
    }
  }

  // macOS path: read the chord from Flutter key events. On Windows the native
  // capture drives commits instead (it suppresses the keys, so this rarely fires
  // there; the guard makes the precedence explicit).
  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (!_recording || _nativeCapturing) return KeyEventResult.ignored;
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final key = e.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      setState(() => _recording = false); // cancel: keep prior value
      return KeyEventResult.handled;
    }
    if (_isModifierKey(key)) return KeyEventResult.handled; // wait for a main key
    final pressed = <HotkeyModifier>{
      if (HardwareKeyboard.instance.isMetaPressed) HotkeyModifier.meta,
      if (HardwareKeyboard.instance.isAltPressed) HotkeyModifier.alt,
      if (HardwareKeyboard.instance.isControlPressed) HotkeyModifier.control,
      if (HardwareKeyboard.instance.isShiftPressed) HotkeyModifier.shift,
    };
    _commit(e.physicalKey, key, pressed);
    return KeyEventResult.handled;
  }

  // Windows path: a key arrived from the native window-proc capture as a Win32
  // vk + modifier mask + a record-time availability probe. Rebuild the Flutter
  // key pair and commit (carrying availability so a taken combo is flagged).
  void _onNativeKey(int vk, int modifierMask, bool available) {
    if (!_recording) return; // ignore stray events after a commit
    final keys = keysForVk(vk);
    if (keys == null) return; // unsupported key -> keep recording
    _commit(keys.physical, keys.logical, modifiersFromWin32Mask(modifierMask),
        available: available);
  }

  void _onNativeCancel() {
    if (!_recording) return;
    _stopCapture();
    setState(() => _recording = false); // keep prior value (Esc)
  }

  // Shared commit: reserved check (keep recording on failure), else store the
  // binding and stop. [available] (Windows probe) is passed through so the host
  // can flag a taken combo + block Apply. Used by both the Flutter and native
  // paths.
  void _commit(PhysicalKeyboardKey physical, LogicalKeyboardKey logical,
      Set<HotkeyModifier> pressed,
      {bool available = true}) {
    _error = null; // re-evaluate fresh on each keystroke
    // Combo-aware reserved check: the full key + modifier set must be known
    // (⌘W is rejected, bare W is allowed).
    if (widget.isReserved?.call(logical, pressed) ?? false) {
      setState(() => _error = AppLocalizations.of(context).recorderReservedKey);
      return;
    }
    _stopCapture();
    widget.onChanged(
      HotkeyBinding(
        physicalKey: physical,
        logicalKey: logical,
        modifiers: pressed,
      ),
      available: available,
    );
    setState(() {
      _recording = false;
      _error = null;
    });
  }

  // The field's fixed trailing slot is contextual: when idle it is a keyboard
  // glyph (= "click here to record"); while recording it becomes a prohibition
  // glyph (= "click to clear / disable this binding" — semantically "no
  // shortcut", clearer than a plain ✕). Clear is therefore reachable only through
  // recording — there is no outside clear button — and the always-present slot
  // never shifts the row left/right.
  Widget _trailingIcon(GlimprTokens t) {
    if (!_recording) {
      return Icon(Icons.keyboard_outlined, size: 15, color: t.fg3);
    }
    return Tooltip(
      message: AppLocalizations.of(context).recorderDisable,
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
          child: Icon(Icons.block, size: 15, color: t.fg2),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Notify on a recording transition (covers every start/stop site) — deferred
    // so it never calls setState mid-build.
    if (_recording != _lastNotifiedRecording) {
      _lastNotifiedRecording = _recording;
      final cb = widget.onRecordingChanged;
      final recording = _recording;
      if (cb != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => cb(recording));
      }
    }
    final t = GlimprTheme.of(context);
    final hasError = _error != null;
    // Red border for an in-progress error OR a committed-but-invalid binding
    // (duplicate / in use), so the problem field stands out, not just its row.
    final showDanger = hasError || widget.hasWarning;
    final borderColor = showDanger
        ? GlimprTokens.danger
        : (_recording ? GlimprTokens.accent : t.fieldBorder);

    // Everything renders inside the fixed-height box (no separate hint line), so
    // the prompt / error never changes the field's — or the row's — height. The
    // always-present trailing slot flips keyboard↔✕ by state (see _trailingIcon),
    // so no element comes/goes to shift the row.
    // Bound the prompt/error width so a long message (e.g. "Needs a modifier
    // (⌘ ⌥ ⌃ ⇧)") can't stretch the field — and the row's trailing — wide enough
    // to overflow a narrow row. The fixed height keeps it to one line, so it
    // ellipsizes rather than wraps. Key-cap combos are short and stay unbounded.
    final Widget primary = _recording
        ? ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 210),
            child: Text(
              _error ?? AppLocalizations.of(context).recorderPressKeys,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GlimprType.sansStyle(
                  12.5, 600, hasError ? GlimprTokens.danger : t.fg2),
            ),
          )
        : KeyCapChips(widget.value,
            emptyLabel: widget.emptyLabel ??
                AppLocalizations.of(context).recorderDisabled);
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
          width: (_recording || showDanger) ? 1.5 : 1,
        ),
      ),
      child: content,
    );
    if (_recording) {
      // Hovering the record area while recording explains the cancel key. The
      // trailing prohibition glyph keeps its own "Disable" tooltip (wins on its
      // own region).
      field = Tooltip(
          message: AppLocalizations.of(context).recorderEscToCancel,
          child: field);
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
