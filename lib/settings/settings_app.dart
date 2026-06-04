import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../editor/editor_controller.dart';
import '../editor/tool_meta.dart';
import '../output/filename.dart';
import '../shortcuts/hotkey_binding.dart';
import '../shortcuts/hotkey_service.dart';
import '../shortcuts/shortcut_actions.dart';
import '../shortcuts/shortcut_store.dart';
import '../shortcuts/widgets/hotkey_recorder_field.dart';
import '../shortcuts/widgets/key_cap_chips.dart';
import '../theme/glimpr_controls.dart';
import '../theme/glimpr_theme.dart';
import 'login_item.dart';
import 'settings.dart';

/// The settings window content: the "Aurora" design — a frosted-glass window
/// (the blur comes from a native NSVisualEffectView behind the Flutter view) with
/// a left sidebar (General / Output / Sounds) over a content pane, in Glimpr's
/// own identity (kept in Flutter so it is identical on macOS + Windows). The
/// theme follows the system light/dark setting. The native window has an inline
/// transparent title bar, so the sidebar runs to the top edge behind the traffic
/// lights — hence the top inset. Each control persists immediately; overlay
/// engines read the values fresh on next capture.
class SettingsApp extends StatefulWidget {
  const SettingsApp({super.key, required this.settings, this.hotkeyService});
  final Settings settings;

  // The live Tier-1 hotkey service from the control engine, used by the
  // Shortcuts pane to re-register a rebound global hotkey on Apply. Null in
  // tests / the overlay engine (which never builds the settings UI).
  final HotkeyService? hotkeyService;

  @override
  State<SettingsApp> createState() => _SettingsAppState();
}

// Reserved at the top for the transparent title bar / traffic lights.
const _kTitleBarInset = 52.0;

const _kSections = <(String, IconData)>[
  ('General', Icons.tune),
  ('Output', Icons.image_outlined),
  ('Sounds', Icons.volume_up_outlined),
  ('Shortcuts', Icons.keyboard),
  ('Advanced', Icons.memory),
];

class _SettingsAppState extends State<SettingsApp>
    with WidgetsBindingObserver {
  int _section = 0;

  String? _saveDir;
  ImageFormat _format = ImageFormat.png;
  int _jpegQuality = 90;
  bool _saveToFile = true;
  bool _copyToClipboard = true;
  bool _shutterSound = true;
  bool _completionSound = true;
  bool _rightClickExits = true;
  bool _launchAtLogin = false;
  int _warmTarget = 2;
  // The warm target active SINCE launch (what OverlayManager actually built with).
  // When the user picks a different value, a restart is needed to apply it.
  int? _warmTargetInitial;
  String _filenameTemplate = defaultFilenameTemplate;
  final _filenameController = TextEditingController();

  // Shortcuts draft: null until the user first opens the Shortcuts pane. Only
  // this pane uses a staged draft (the other panes are live-apply). The baseline
  // is the last-applied state; Revert restores it and the Apply/Revert buttons
  // show only when the draft differs from it.
  late final _shortcutStore = ShortcutStore(widget.settings.store);
  Map<String, HotkeyBinding?>? _shortcutsDraft;
  Map<String, HotkeyBinding?> _shortcutsBaseline = const {};

  Settings get _s => widget.settings;

  // Cmd-W hides the settings window (the native control window handles it the
  // same way as the close button — see MainFlutterWindow's role channel).
  static const _roleChannel = MethodChannel('glimpr/role');
  void _close() => _roleChannel.invokeMethod('closeSettings');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _filenameController.dispose();
    super.dispose();
  }

  // Follow the system appearance: rebuild when it flips so the token set swaps.
  @override
  void didChangePlatformBrightness() => setState(() {});

  Future<void> _load() async {
    final dir = await _s.getSaveDirectory();
    final format = await _s.getFormat();
    final quality = await _s.getJpegQuality();
    final saveToFile = await _s.getSaveToFile();
    final clip = await _s.getCopyToClipboard();
    final shutter = await _s.getShutterSound();
    final complete = await _s.getCompletionSound();
    final rightClick = await _s.getRightClickExits();
    final template = await _s.getFilenameTemplate();
    if (!mounted) return;
    setState(() {
      _saveDir = dir;
      _format = format;
      _jpegQuality = quality;
      _saveToFile = saveToFile;
      _copyToClipboard = clip;
      _shutterSound = shutter;
      _completionSound = complete;
      _rightClickExits = rightClick;
      _filenameTemplate = template;
    });
    _filenameController.text = template;
    // Login state comes from the OS (SMAppService) over a native channel; query
    // it separately so a slow / unavailable channel never blocks the rest of the
    // settings UI (and never stalls widget tests where the channel is unmocked).
    final login = await LoginItem.isEnabled();
    if (mounted) setState(() => _launchAtLogin = login);
    // Warm-display target lives natively (UserDefaults, read by OverlayManager at
    // launch). Query it over the role channel; guard so an unmocked channel never
    // breaks the rest of the UI.
    try {
      final warm = await _roleChannel.invokeMethod<int>('getOverlayWarmTarget');
      if (mounted) {
        setState(() {
          _warmTarget = warm ?? 2;
          _warmTargetInitial = warm ?? 2;
        });
      }
    } catch (_) {}
  }

  Future<void> _chooseDir() async {
    final picked = await getDirectoryPath();
    if (picked == null) return;
    await _s.setSaveDirectory(picked);
    if (mounted) setState(() => _saveDir = picked);
  }

  Future<void> _resetDir() async {
    await _s.clearSaveDirectory();
    if (mounted) setState(() => _saveDir = null);
  }

  Future<void> _setWarmTarget(int v) async {
    try {
      await _roleChannel.invokeMethod('setOverlayWarmTarget', v);
    } catch (_) {}
    if (mounted) setState(() => _warmTarget = v);
  }

  @override
  Widget build(BuildContext context) {
    final brightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    final tokens = GlimprTokens.forBrightness(brightness);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: brightness,
        scaffoldBackgroundColor: Colors.transparent,
        fontFamily: GlimprType.sans,
      ),
      home: GlimprTheme(
        tokens: tokens,
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyW, meta: true): _close,
          },
          child: Focus(
            autofocus: true,
            // The base glass tint that layers over the native vibrancy blur.
            child: Material(
              type: MaterialType.transparency,
              child: ColoredBox(
                color: tokens.winBg,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _sidebar(tokens),
                    Container(width: 1, color: tokens.divider),
                    Expanded(child: _content(tokens)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---- sidebar -----------------------------------------------------------

  Widget _sidebar(GlimprTokens t) {
    return Container(
      width: 212,
      color: t.sidebarBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Traffic-light zone (real macOS controls overlay this area).
          const SizedBox(height: _kTitleBarInset),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
            child: const Lockup(),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              children: [
                for (var i = 0; i < _kSections.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1.5),
                    child: NavItem(
                      icon: _kSections[i].$2,
                      label: _kSections[i].$1,
                      active: _section == i,
                      onTap: () => setState(() => _section = i),
                    ),
                  ),
              ],
            ),
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Glimpr 1.0.0',
              style: GlimprType.sansStyle(11.5, 500, t.fg4),
            ),
          ),
        ],
      ),
    );
  }

  // ---- content -----------------------------------------------------------

  Widget _content(GlimprTokens t) {
    final list = ListView(
      padding: const EdgeInsets.fromLTRB(28, _kTitleBarInset, 28, 32),
      children: _pane(t),
    );
    // The Shortcuts pane is long; pin its Apply/Revert bar to the bottom so it's
    // always reachable without scrolling to the end of the list.
    if (_section == 3) {
      return Column(
        children: [Expanded(child: list), _shortcutsFooter(t)],
      );
    }
    return list;
  }

  List<Widget> _pane(GlimprTokens t) {
    switch (_section) {
      case 1:
        return _outputPane(t);
      case 2:
        return _soundsPane(t);
      case 3:
        return _shortcutsPane(t);
      case 4:
        return _advancedPane(t);
      default:
        return _generalPane(t);
    }
  }

  // ---- panes -------------------------------------------------------------

  List<Widget> _generalPane(GlimprTokens t) {
    return [
      _h1('General', t),
      const SectionLabel('Save location', icon: Icons.folder_outlined),
      GlassCard.padded(child: _saveFolderBody(t)),
      const SizedBox(height: 15),
      const SectionLabel('Destinations', icon: Icons.layers_outlined),
      GlassCard.rows([
        SettingRow(
          title: 'Save to file',
          hint: 'Write the capture to the save folder',
          trailing: GlassToggle(
            value: _saveToFile,
            onChanged: (v) async {
              await _s.setSaveToFile(v);
              if (mounted) setState(() => _saveToFile = v);
            },
          ),
        ),
        SettingRow(
          divider: true,
          title: 'Copy to clipboard',
          hint: 'Put the image on the clipboard',
          trailing: GlassToggle(
            value: _copyToClipboard,
            onChanged: (v) async {
              await _s.setCopyToClipboard(v);
              if (mounted) setState(() => _copyToClipboard = v);
            },
          ),
        ),
      ]),
      const SizedBox(height: 15),
      const SectionLabel('Capture', icon: Icons.photo_camera_outlined),
      GlassCard.rows([
        SettingRow(
          title: 'Right-click exits',
          hint: 'Right-click leaves capture mode (Esc always works)',
          trailing: GlassToggle(
            value: _rightClickExits,
            onChanged: (v) async {
              await _s.setRightClickExits(v);
              if (mounted) setState(() => _rightClickExits = v);
            },
          ),
        ),
      ]),
      const SizedBox(height: 15),
      const SectionLabel('Startup', icon: Icons.power_settings_new),
      GlassCard.rows([
        SettingRow(
          title: 'Launch at login',
          hint: 'Start Glimpr automatically when you log in',
          trailing: GlassToggle(
            value: _launchAtLogin,
            onChanged: (v) async {
              final actual = await LoginItem.setEnabled(v);
              if (mounted) setState(() => _launchAtLogin = actual);
            },
          ),
        ),
      ]),
    ];
  }

  List<Widget> _outputPane(GlimprTokens t) {
    final lossy = _format == ImageFormat.jpeg;
    return [
      _h1('Output', t),
      const SectionLabel('Format', icon: Icons.image_outlined),
      GlassCard.padded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Segmented<ImageFormat>(
              full: true,
              value: _format,
              options: const [
                (ImageFormat.png, 'PNG'),
                (ImageFormat.jpeg, 'JPEG'),
              ],
              onChanged: (f) async {
                await _s.setFormat(f);
                if (mounted) setState(() => _format = f);
              },
            ),
            // Quality applies to JPEG only. Slide + fade it in/out on format
            // switch (collapses to zero height for PNG, which is lossless).
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 200),
              alignment: Alignment.topCenter,
              sizeCurve: Curves.easeOutCubic,
              firstCurve: Curves.easeOut,
              secondCurve: Curves.easeOut,
              crossFadeState: lossy
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              firstChild: const SizedBox(width: double.infinity, height: 0),
              secondChild: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 18),
                  Divider(height: 1, thickness: 1, color: t.divider),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      SizedBox(
                        width: 130,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Quality',
                              style: GlimprType.sansStyle(14.5, 600, t.fg1),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Compression level',
                              style: GlimprType.sansStyle(12.5, 400, t.fg3),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: GlimprSlider(
                          value: _jpegQuality.toDouble(),
                          min: 10,
                          max: 100,
                          suffix: '%',
                          onChanged: (v) =>
                              setState(() => _jpegQuality = v.round()),
                          onChangeEnd: (v) => _s.setJpegQuality(v.round()),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 15),
      const SectionLabel('Filename', icon: Icons.text_fields_outlined),
      GlassCard.padded(child: _filenameBody(t)),
    ];
  }

  Widget _filenameBody(GlimprTokens t) {
    final preview = buildScreenshotName(
      template: _filenameTemplate.trim().isEmpty
          ? defaultFilenameTemplate
          : _filenameTemplate,
      t: DateTime.now(),
      windowTitle: 'Safari',
      appName: 'Safari',
      ext: _format == ImageFormat.jpeg ? 'jpg' : 'png',
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _filenameController,
          style: GlimprType.mono(13, t.fg1),
          cursorColor: GlimprTokens.accent,
          onChanged: (v) {
            _s.setFilenameTemplate(v);
            setState(() => _filenameTemplate = v);
          },
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: t.fieldBg,
            hintText: defaultFilenameTemplate,
            hintStyle: GlimprType.mono(13, t.fg4),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 11,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(9),
              borderSide: BorderSide(color: t.fieldBorder),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(9),
              borderSide: const BorderSide(
                color: GlimprTokens.accent,
                width: 1.5,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Text('Preview', style: GlimprType.sansStyle(12.5, 600, t.fg4)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                preview,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GlimprType.mono(12.5, t.fg3),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text('Placeholders', style: GlimprType.sansStyle(12.5, 600, t.fg4)),
        const SizedBox(height: 8),
        _token(t, '{window}', 'The window title, or the app name if it has none'),
        _token(t, '{app}', 'The application name (e.g. Safari)'),
        _token(t, '{date}', 'Capture date — 2026-06-03'),
        _token(t, '{time}', 'Capture time — 15-04-09'),
        const SizedBox(height: 6),
        Text(
          'Uses the window under the cursor when the capture ends. On bare '
          'desktop, {window} and {app} are left out.',
          style: GlimprType.sansStyle(12, 400, t.fg4),
        ),
      ],
    );
  }

  Widget _token(GlimprTokens t, String token, String desc) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 82,
            child: Text(
              token,
              style: GlimprType.mono(12.5, GlimprTokens.accent),
            ),
          ),
          Expanded(
            child: Text(desc, style: GlimprType.sansStyle(12.5, 400, t.fg3)),
          ),
        ],
      ),
    );
  }

  List<Widget> _soundsPane(GlimprTokens t) {
    return [
      _h1('Sounds', t),
      const SectionLabel('Sound', icon: Icons.volume_up_outlined),
      GlassCard.rows([
        SettingRow(
          title: 'Shutter',
          hint: 'Plays the instant a capture is taken',
          trailing: GlassToggle(
            value: _shutterSound,
            onChanged: (v) async {
              await _s.setShutterSound(v);
              if (mounted) setState(() => _shutterSound = v);
            },
          ),
        ),
        SettingRow(
          divider: true,
          title: 'Completion',
          hint: 'Chimes once the capture is saved / copied',
          trailing: GlassToggle(
            value: _completionSound,
            onChanged: (v) async {
              await _s.setCompletionSound(v);
              if (mounted) setState(() => _completionSound = v);
            },
          ),
        ),
      ]),
    ];
  }

  List<Widget> _advancedPane(GlimprTokens t) {
    return [
      _h1('Advanced', t),
      const SectionLabel('Multi-display', icon: Icons.memory),
      GlassCard.padded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Warm capture engines',
              style: GlimprType.sansStyle(14.5, 600, t.fg1),
            ),
            const SizedBox(height: 4),
            Text(
              'How many displays Glimpr keeps instantly capture-ready — including '
              'displays connected after the app has launched (e.g. plugging into a '
              'dock). Glimpr pre-warms a rendering engine per display so the freeze '
              'overlay appears with no delay.\n\n'
              'Cost: each engine uses about 100 MB of memory while Glimpr runs. A '
              'display connected beyond this number still captures, but only shows '
              'the frozen frame — its crosshair and toolbar follow correctly after a '
              'restart (which makes every connected display warm again).',
              style: GlimprType.sansStyle(12.5, 400, t.fg3),
            ),
            const SizedBox(height: 16),
            Segmented<int>(
              full: true,
              value: _warmTarget.clamp(1, 5),
              options: const [(1, '1'), (2, '2'), (3, '3'), (4, '4'), (5, '5')],
              onChanged: _setWarmTarget,
            ),
            const SizedBox(height: 12),
            if (_warmTargetInitial != null && _warmTarget != _warmTargetInitial)
              Row(
                children: [
                  const Icon(
                    Icons.restart_alt,
                    size: 15,
                    color: GlimprTokens.danger,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Restart Glimpr for this to take effect.',
                      style: GlimprType.sansStyle(12.5, 600, GlimprTokens.danger),
                    ),
                  ),
                ],
              )
            else
              Text(
                'Default 2 · applies after restarting Glimpr',
                style: GlimprType.sansStyle(12, 500, t.fg4),
              ),
          ],
        ),
      ),
    ];
  }

  // ---- shortcuts ---------------------------------------------------------

  // Loads the effective bindings (defaults merged with stored overrides) into the
  // draft + baseline the first time the Shortcuts pane is shown.
  Future<void> _ensureShortcutsDraft() async {
    if (_shortcutsDraft != null) return;
    final all = await _shortcutStore.all();
    if (!mounted) return;
    setState(() {
      _shortcutsDraft = {...all};
      _shortcutsBaseline = {...all};
    });
  }

  List<Widget> _shortcutsPane(GlimprTokens t) {
    final draft = _shortcutsDraft;
    if (draft == null) {
      _ensureShortcutsDraft();
      return const [Center(child: CircularProgressIndicator())];
    }
    final dupes = duplicateActionKeys(draft);

    return [
      _h1('Shortcuts', t),
      const SectionLabel('Global', icon: Icons.public),
      GlassCard.rows([
        for (final a in kGlobalActions)
          SettingRow(
            title: a.label,
            hint: a.hint,
            trailing: _bindingRow(
              t: t,
              actionKey: a.actionKey,
              requireModifier: true,
              reserved: const {},
              dupes: dupes,
            ),
          ),
      ]),
      const SizedBox(height: 24),
      const SectionLabel('Toolbar/Editor', icon: Icons.edit_outlined),
      GlassCard.rows([
        for (final cmd in const <(String, String, String?)>[
          (kEditorUndoKey, 'Undo', null),
          (kEditorRedoKey, 'Redo', null),
          (kEditorPasteKey, 'Paste image', 'From the clipboard'),
          (kEditorDeleteKey, 'Delete selected', 'Remove the selected annotation'),
          (
            kEditorConfirmKey,
            'Export',
            'Screenshot the snapped window, or the whole screen',
          ),
        ])
          SettingRow(
            title: cmd.$2,
            hint: cmd.$3,
            trailing: _bindingRow(
              t: t,
              actionKey: cmd.$1,
              requireModifier: false,
              reserved: kEditorReservedKeys,
              dupes: dupes,
            ),
          ),
        // Tools, in toolbar order, each with its toolbar icon (shared SSOT).
        for (final (tool, icon) in kEditorToolMeta)
          SettingRow(
            title: _toolLabel(tool),
            icon: icon,
            trailing: _bindingRow(
              t: t,
              actionKey: kEditorToolActionKey[tool]!,
              requireModifier: false,
              reserved: kEditorReservedKeys,
              dupes: dupes,
            ),
          ),
        // Reserved (read-only) — fixed keys that cannot be rebound. Rendered in a
        // field-shaped box matching the recorder so the caps line up with the
        // editable rows (a lock glyph replaces the recorder's keyboard/✕ glyph).
        SettingRow(
          title: 'Cancel / Exit',
          hint: 'Reserved',
          trailing: _reservedField(t, const [KeyCap('esc')]),
        ),
        SettingRow(
          title: 'Nudge crosshair',
          hint: 'Reserved · region tools',
          trailing: _reservedField(
            t,
            const [KeyCap('←'), KeyCap('↑'), KeyCap('↓'), KeyCap('→')],
          ),
        ),
        // Text-input semantics, fixed while editing a text annotation — one row
        // per action so the keys don't read as a single chord.
        SettingRow(
          title: 'Commit text',
          hint: 'Reserved · while editing text',
          trailing: _reservedField(t, const [KeyCap('⏎')]),
        ),
        SettingRow(
          title: 'New line',
          hint: 'Reserved · while editing text',
          trailing: _reservedField(t, const [KeyCap('⇧'), KeyCap('⏎')]),
        ),
        SettingRow(
          title: 'Cancel text',
          hint: 'Reserved · while editing text',
          trailing: _reservedField(t, const [KeyCap('esc')]),
        ),
      ]),
    ];
  }

  // The Shortcuts pane's Apply/Revert bar, pinned to the bottom of the content
  // area (see _content) so it stays reachable however long the list grows. Only
  // shown when the draft is dirty; Apply is disabled (rendered as a dead ghost)
  // when the draft is invalid (duplicate / missing-modifier).
  Widget _shortcutsFooter(GlimprTokens t) {
    final draft = _shortcutsDraft;
    if (draft == null || _mapEquals(draft, _shortcutsBaseline)) {
      return const SizedBox.shrink();
    }
    final allValid = _allValid(draft, duplicateActionKeys(draft));
    return Container(
      padding: const EdgeInsets.fromLTRB(28, 12, 28, 16),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: t.divider)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          GhostButton('Revert', onTap: _revertShortcuts),
          const SizedBox(width: 8),
          if (allValid)
            AccentButton('Apply', onTap: _applyShortcuts)
          else
            GhostButton('Apply', onTap: null),
        ],
      ),
    );
  }

  Widget _bindingRow({
    required GlimprTokens t,
    required String actionKey,
    required bool requireModifier,
    required Set<LogicalKeyboardKey> reserved,
    required Set<String> dupes,
  }) {
    final draft = _shortcutsDraft!;
    final binding = draft[actionKey];
    final isDefault = binding == kDefaultBindings[actionKey];
    final needsModifier =
        requireModifier && binding != null && !binding.hasModifier;
    final isDupe = dupes.contains(actionKey);
    final warning = needsModifier
        ? 'Needs a modifier'
        : (isDupe ? 'Duplicate' : null);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (warning != null) ...[
          Text(
            warning,
            style: GlimprType.sansStyle(11.5, 600, GlimprTokens.danger),
          ),
          const SizedBox(width: 10),
        ],
        HotkeyRecorderField(
          value: binding,
          requireModifier: requireModifier,
          reservedKeys: reserved,
          onChanged: (b) => setState(() => draft[actionKey] = b),
        ),
        const SizedBox(width: 4),
        // Reset to default — disabled + dimmed when the binding already is the
        // default (nothing to reset), so it reads as inactive.
        Opacity(
          opacity: isDefault ? 0.25 : 1,
          child: IconButton(
            tooltip: isDefault ? null : 'Reset to default',
            icon: Icon(Icons.restart_alt, size: 18, color: t.fg3),
            onPressed: isDefault
                ? null
                : () => setState(
                    () => draft[actionKey] = kDefaultBindings[actionKey]),
          ),
        ),
      ],
    );
  }

  // Valid when there are no duplicate combos and every present global binding has
  // a modifier (a bare global hotkey is rejected — Tier 1 requires a modifier).
  bool _allValid(Map<String, HotkeyBinding?> draft, Set<String> dupes) {
    if (dupes.isNotEmpty) return false;
    for (final a in kGlobalActions) {
      final b = draft[a.actionKey];
      if (b != null && !b.hasModifier) return false;
    }
    return true;
  }

  Future<void> _applyShortcuts() async {
    final draft = _shortcutsDraft!;
    await _shortcutStore.saveAll(draft);
    // Re-register the changed Tier-1 actions live (no restart).
    for (final a in kGlobalActions) {
      if (draft[a.actionKey] != _shortcutsBaseline[a.actionKey]) {
        await widget.hotkeyService?.rebind(a.actionKey, draft[a.actionKey]);
      }
    }
    if (mounted) setState(() => _shortcutsBaseline = {...draft});
  }

  void _revertShortcuts() =>
      setState(() => _shortcutsDraft = {..._shortcutsBaseline});

  // Entry-wise equality for two binding maps (HotkeyBinding has value equality).
  bool _mapEquals(
    Map<String, HotkeyBinding?> a,
    Map<String, HotkeyBinding?> b,
  ) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key) || b[entry.key] != entry.value) return false;
    }
    return true;
  }

  // ---- building blocks ---------------------------------------------------

  Widget _h1(String title, GlimprTokens t) => Padding(
    padding: const EdgeInsets.only(bottom: 22),
    child: Text(
      title,
      style: GlimprType.sansStyle(25, 700, t.fg1, letterSpacing: -0.5),
    ),
  );

  String _toolLabel(ToolKind t) => switch (t) {
        ToolKind.crop => 'Crop',
        ToolKind.blur => 'Blur',
        ToolKind.pixelate => 'Pixelate',
        ToolKind.rectangle => 'Rectangle',
        ToolKind.ellipse => 'Ellipse',
        ToolKind.line => 'Line',
        ToolKind.arrow => 'Arrow',
        ToolKind.pen => 'Pen',
        ToolKind.text => 'Text',
        ToolKind.highlighter => 'Highlighter',
        ToolKind.step => 'Numbered step',
        // The "paste" tool selects/edits pasted clipboard images; the paste
        // ACTION is the Cmd-V "Paste image" command above. Labelled "Image" to
        // avoid colliding with that command.
        ToolKind.paste => 'Image',
      };

  // A read-only, field-shaped box for reserved (fixed) keys, mirroring the
  // HotkeyRecorderField's idle look (same height / bg / border) so the reserved
  // caps line up with the editable rows. A lock glyph fills the trailing slot
  // where the recorder shows its keyboard/✕ glyph.
  Widget _reservedField(GlimprTokens t, List<Widget> caps) => Container(
    height: 42,
    padding: const EdgeInsets.symmetric(horizontal: 8),
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: t.fieldBg,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: t.fieldBorder),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(spacing: 5, children: caps),
        const SizedBox(width: 8),
        Icon(Icons.lock_outline, size: 15, color: t.fg3),
      ],
    ),
  );

  Widget _saveFolderBody(GlimprTokens t) {
    final path = _saveDir;
    final mono = GlimprType.mono(12.5, t.fg3);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Label + actions on the top row; the path gets its own full-width line
        // below so it is not squeezed into half the card.
        Row(
          children: [
            Expanded(
              child: Text(
                'Save folder',
                style: GlimprType.sansStyle(14.5, 600, t.fg1),
              ),
            ),
            const SizedBox(width: 14),
            AccentButton(
              'Choose…',
              icon: Icons.folder_open_outlined,
              onTap: _chooseDir,
            ),
            const SizedBox(width: 8),
            GhostButton('Reset', onTap: path == null ? null : _resetDir),
          ],
        ),
        const SizedBox(height: 10),
        if (path == null)
          Text('Default · ~/Pictures/Glimpr', style: mono)
        else
          Tooltip(
            message: path,
            waitDuration: const Duration(milliseconds: 400),
            child: _pathLine(path, mono),
          ),
      ],
    );
  }

  // A full-width path that keeps the LAST folder visible: the head ellipsizes
  // when space runs out, the trailing segment stays. Hover shows the full path.
  Widget _pathLine(String path, TextStyle style) {
    final i = path.lastIndexOf('/');
    if (i <= 0) {
      return Text(
        path,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }
    return Row(
      children: [
        // Loose Flexible: takes its content width (so head + tail stay contiguous)
        // and only shrinks/ellipsizes the head when the line runs out of room.
        Flexible(
          child: Text(
            path.substring(0, i),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
        Text(path.substring(i), maxLines: 1, softWrap: false, style: style),
      ],
    );
  }
}
