import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../editor/editor_controller.dart' show ToolKind;
import '../editor/loupe_config.dart';
import '../l10n/gen/app_localizations.dart';
import 'app_locale.dart';
import '../editor/tool_meta.dart';
import '../overlay/crop_hud.dart';
import '../output/filename.dart';
import '../output/flow.dart';
import '../record/record_bridge.dart';
import '../shortcuts/hotkey_binding.dart';
import '../shortcuts/hotkey_service.dart';
import '../shortcuts/shortcut_actions.dart';
import '../shortcuts/shortcut_store.dart';
import '../shortcuts/widgets/hotkey_recorder_field.dart';
import '../shortcuts/widgets/key_cap_chips.dart';
import '../editor/tool_style_store.dart';
import '../image_editor/recent_images.dart';
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

// Side of the square Loupe preview frame. A loupe larger than this is scaled
// down to fit (and flagged), so the section never reflows while dragging.
const double _kLoupePreviewStage = 200;

// Sidebar order follows the user's pipeline: how to capture -> what gets
// produced (and where) -> what happens on completion; General keeps the
// app-level items, Advanced the expert/danger zone.
const _kSections = <(String, IconData)>[
  ('General', Icons.tune),
  ('Capture', Icons.photo_camera_outlined),
  ('Recording', Icons.videocam_outlined),
  ('Output', Icons.image_outlined),
  ('Workflow', Icons.checklist),
  ('Shortcuts', Icons.keyboard),
  ('Advanced', Icons.memory),
];

class _SettingsAppState extends State<SettingsApp>
    with WidgetsBindingObserver {
  // Resolved once per build frame inside the MaterialApp's localizations scope
  // (set in the Builder in build()). Using a field instead of a context-arg
  // avoids threading BuildContext through every helper method.
  late AppLocalizations _l;

  int _section = 0;

  String? _saveDir;
  ImageFormat _format = ImageFormat.png;
  int _jpegQuality = 90;
  Set<FlowAction> _afterCapture = {FlowAction.copy, FlowAction.save};
  Set<FlowAction> _afterEditorDone = {FlowAction.copy, FlowAction.save};
  bool _shutterSound = true;
  bool _completionSound = true;
  bool _rightClickExits = true;
  bool _confirmOnExit = true;
  bool _captureCursor = false;
  bool _launchAtLogin = false;
  int _warmTarget = 2;
  int _recentCap = kRecentImagesCap;
  int _captureLayerCap = 1;
  // App language choice + the value active since launch (restart-effective,
  // like the warm target): the restart hint shows while they differ.
  String _appLanguage = 'system';
  String? _appLanguageInitial;
  // The warm target active SINCE launch (what OverlayManager actually built with).
  // When the user picks a different value, a restart is needed to apply it.
  int? _warmTargetInitial;
  String _filenameTemplate = defaultFilenameTemplate;
  // Opt-in capture decoration, per scenario (all off by default).
  bool _decorateSnap = false;
  bool _decorateCrop = false;
  bool _decorateWindow = false;
  bool _decorateDisplay = false;
  bool _decorateLastRegion = false;
  int _decorationJpegFill = 0xFFFFFFFF;
  // Screen recording (macOS 15+ module; the card shows an unavailable hint
  // below 15).
  bool _recordAvailable = false;
  RecordFormat _recordFormat = RecordFormat.h264;
  int _recordFps = 30;
  int _recordCountdown = 0;
  int _recordMaxDuration = 0;
  bool _recordShowCursor = true;
  bool _recordSystemAudio = false;
  bool _recordMicrophone = false;
  Set<FlowAction> _afterRecording = {};
  int _loupeSpan = kLoupeSpanDefault;
  int _loupeZoom = kLoupeZoomDefault;
  bool _eyedropperKeysCancel = true;
  bool _hudCrosshair = true;
  bool _hudMarchingAnts = true;
  final _filenameController = TextEditingController();

  // Shortcuts draft: null until the user first opens the Shortcuts pane. Only
  // this pane uses a staged draft (the other panes are live-apply). The baseline
  // is the last-applied state; Revert restores it and the Apply/Revert buttons
  // show only when the draft differs from it.
  late final _shortcutStore = ShortcutStore(widget.settings.store);
  Map<String, HotkeyBinding?>? _shortcutsDraft;
  Map<String, HotkeyBinding?> _shortcutsBaseline = const {};
  // While any recorder is recording, the live global hotkeys are suspended so a
  // system-registered combo reaches the recorder instead of firing its action.
  int _activeRecorders = 0;

  void _onRecordingChanged(bool recording) {
    final wasRecording = _activeRecorders > 0;
    _activeRecorders = (_activeRecorders + (recording ? 1 : -1)).clamp(0, 999);
    final nowRecording = _activeRecorders > 0;
    if (nowRecording && !wasRecording) widget.hotkeyService?.pauseAll();
    if (!nowRecording && wasRecording) widget.hotkeyService?.resumeAll();
    if (nowRecording != wasRecording) {
      // Also pause the NATIVE window-level interceptors (⌘W close-window key
      // equivalent) so combos like ⌘W / ⌘⇧W are recordable too.
      _roleChannel.invokeMethod('setShortcutRecording', nowRecording);
    }
  }

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
    final afterCapture = await _s.getAfterCaptureFlow();
    final afterEditorDone = await _s.getAfterEditorDoneFlow();
    final shutter = await _s.getShutterSound();
    final complete = await _s.getCompletionSound();
    final rightClick = await _s.getRightClickExits();
    final confirmOnExit = await _s.getConfirmOnExit();
    final captureCursor = await _s.getCaptureCursor();
    final template = await _s.getFilenameTemplate();
    final decSnap = await _s.getDecorateSnap();
    final decCrop = await _s.getDecorateCrop();
    final decWindow = await _s.getDecorateWindow();
    final decDisplay = await _s.getDecorateDisplay();
    final decLast = await _s.getDecorateLastRegion();
    final decFill = await _s.getDecorationJpegFill();
    final loupeSpan = await _s.getLoupeSpan();
    final loupeZoom = await _s.getLoupeZoom();
    final eyedropperKeys = await _s.getEyedropperToolKeysCancel();
    final hudCrosshair = await _s.getHudCrosshair();
    final hudMarchingAnts = await _s.getHudMarchingAnts();
    final layerCap = await _s.getCaptureLayerCap();
    final appLanguage = await _s.getAppLanguage();
    final rec = await _s.loadRecording();
    if (!mounted) return;
    setState(() {
      _saveDir = dir;
      _format = format;
      _jpegQuality = quality;
      _afterCapture = afterCapture;
      _afterEditorDone = afterEditorDone;
      _shutterSound = shutter;
      _completionSound = complete;
      _rightClickExits = rightClick;
      _confirmOnExit = confirmOnExit;
      _captureCursor = captureCursor;
      _filenameTemplate = template;
      _decorateSnap = decSnap;
      _decorateCrop = decCrop;
      _decorateWindow = decWindow;
      _decorateDisplay = decDisplay;
      _decorateLastRegion = decLast;
      _decorationJpegFill = decFill;
      _loupeSpan = loupeSpan;
      _loupeZoom = loupeZoom;
      _eyedropperKeysCancel = eyedropperKeys;
      _hudCrosshair = hudCrosshair;
      _hudMarchingAnts = hudMarchingAnts;
      _captureLayerCap = layerCap;
      _appLanguage = appLanguage;
      _appLanguageInitial = appLanguage;
      _recordFormat = rec.format;
      _recordFps = rec.fps;
      _recordCountdown = rec.countdown;
      _recordMaxDuration = rec.maxDuration;
      _recordShowCursor = rec.showCursor;
      _recordSystemAudio = rec.systemAudio;
      _recordMicrophone = rec.microphone;
      _afterRecording = rec.flow;
    });
    _filenameController.text = template;
    // Recording availability is a native (macOS version) fact; guard so an
    // unmocked channel never breaks the rest of the UI (widget tests).
    final recordAvailable = await RecordBridge().isAvailable();
    if (mounted) setState(() => _recordAvailable = recordAvailable);
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
    final recentCap = await RecentImagesStore.getCap(_s.store);
    if (mounted) setState(() => _recentCap = recentCap);
  }

  /// Toggle one action in a completion flow and persist it. copy and copyPath
  /// are mutually exclusive (both write the clipboard) — checking one unchecks
  /// the other.
  Future<void> _setFlowAction({
    required bool capture,
    required FlowAction action,
    required bool on,
  }) async {
    final next = {...(capture ? _afterCapture : _afterEditorDone)};
    if (on) {
      next.add(action);
      if (action == FlowAction.copy) next.remove(FlowAction.copyPath);
      if (action == FlowAction.copyPath) next.remove(FlowAction.copy);
    } else {
      next.remove(action);
    }
    if (capture) {
      await _s.setAfterCaptureFlow(next);
      if (mounted) setState(() => _afterCapture = next);
    } else {
      await _s.setAfterEditorDoneFlow(next);
      if (mounted) setState(() => _afterEditorDone = next);
    }
  }

  /// The toggle rows for one completion-flow card. copyPath / showInFinder need
  /// a saved file, so they are disabled (dimmed) until save is checked.
  List<Widget> _flowRows({required bool capture}) {
    final flow = capture ? _afterCapture : _afterEditorDone;
    final hasSave = flow.contains(FlowAction.save);

    Widget toggle(FlowAction a, {bool enabled = true}) {
      final t = GlassToggle(
        value: flow.contains(a),
        onChanged: (v) => _setFlowAction(capture: capture, action: a, on: v),
      );
      return enabled
          ? t
          : Opacity(opacity: 0.35, child: IgnorePointer(child: t));
    }

    return [
      SettingRow(
        title: _l.settingsFlowCopyToClipboard,
        hint: _l.settingsFlowCopyToClipboardHint,
        trailing: toggle(FlowAction.copy),
      ),
      SettingRow(
        divider: true,
        title: _l.settingsFlowSaveToFile,
        hint: _l.settingsFlowSaveToFileHint,
        trailing: toggle(FlowAction.save),
      ),
      SettingRow(
        divider: true,
        title: _l.settingsFlowCopyFilePath,
        hint: hasSave
            ? _l.settingsFlowCopyFilePathHint
            : _l.settingsFlowCopyFilePathNeedsSave,
        trailing: toggle(FlowAction.copyPath, enabled: hasSave),
      ),
      SettingRow(
        divider: true,
        title: _l.settingsFlowShowInFinder,
        hint: hasSave
            ? _l.settingsFlowShowInFinderHint
            : _l.settingsFlowCopyFilePathNeedsSave,
        trailing: toggle(FlowAction.showInFinder, enabled: hasSave),
      ),
      if (capture)
        SettingRow(
          divider: true,
          title: _l.settingsFlowOpenInEditor,
          hint: _l.settingsFlowOpenInEditorHint,
          trailing: toggle(FlowAction.openEditor),
        ),
      SettingRow(
        divider: true,
        title: _l.settingsFlowShareSheet,
        hint: _l.settingsFlowShareSheetHint,
        trailing: toggle(FlowAction.shareSheet),
      ),
      SettingRow(
        divider: true,
        title: _l.settingsFlowPinToScreen,
        hint: capture
            ? _l.settingsFlowPinToScreenCaptureHint
            : _l.settingsFlowPinToScreenEditorHint,
        trailing: toggle(FlowAction.pin),
      ),
    ];
  }

  /// Muted caption under a flow card: when it runs, plus the empty-selection
  /// fallback warning.
  Widget _flowCaption(GlimprTokens t, {required bool capture}) {
    final flow = capture ? _afterCapture : _afterEditorDone;
    final String text;
    if (flow.isEmpty) {
      text = capture
          ? _l.settingsFlowCaptureCaptionEmpty
          : _l.settingsFlowEditorCaptionEmpty;
    } else {
      text = capture
          ? _l.settingsFlowCaptureCaption
          : _l.settingsFlowEditorCaption;
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
      child: Text(
        text,
        style: GlimprType.sansStyle(
            12, 500, flow.isEmpty ? GlimprTokens.danger : t.fg4,
            height: 1.4),
      ),
    );
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

  void _setCaptureLayerCap(int v) {
    _s.setCaptureLayerCap(v);
    setState(() => _captureLayerCap = v);
  }

  void _setAppLanguage(String v) {
    _s.setAppLanguage(v);
    setState(() => _appLanguage = v);
  }

  @override
  Widget build(BuildContext context) {
    final brightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    final tokens = GlimprTokens.forBrightness(brightness);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: appLocaleOverride,
      localeListResolutionCallback: resolveAppLocale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: ThemeData(
        brightness: brightness,
        scaffoldBackgroundColor: Colors.transparent,
        fontFamily: GlimprType.sans,
        tooltipTheme: glimprTooltipTheme(brightness),
      ),
      home: GlimprTheme(
        tokens: tokens,
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyW, meta: true): _close,
          },
          child: Focus(
            autofocus: true,
            // No tint layer: the window is pure native vibrancy (design guide
            // — Apple liquid glass, tint removed app-wide 2026-06-13).
            child: Material(
              type: MaterialType.transparency,
              child: Builder(
                builder: (ctx) {
                  // Resolve localizations from a context that is inside the
                  // MaterialApp's Localizations scope (not the outer context).
                  _l = AppLocalizations.of(ctx);
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _sidebar(tokens),
                      Container(width: 1, color: tokens.divider),
                      Expanded(child: _content(tokens)),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---- sidebar -----------------------------------------------------------

  // Maps section index to the localized pane title. Must stay in sync with
  // _kSections order and _pane()'s switch.
  String _sectionTitle(int i) {
    switch (i) {
      case 1: return _l.settingsPaneCapture;
      case 2: return _l.settingsPaneRecording;
      case 3: return _l.settingsPaneOutput;
      case 4: return _l.settingsPaneWorkflow;
      case 5: return _l.settingsPaneShortcuts;
      case 6: return _l.settingsPaneAdvanced;
      default: return _l.settingsPaneGeneral;
    }
  }

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
                      label: _sectionTitle(i),
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
    if (_section == 5) {
      return Column(
        children: [Expanded(child: list), _shortcutsFooter(t)],
      );
    }
    return list;
  }

  List<Widget> _pane(GlimprTokens t) {
    switch (_section) {
      case 1:
        return _capturePane(t);
      case 2:
        return _recordingPane(t);
      case 3:
        return _outputPane(t);
      case 4:
        return _workflowPane(t);
      case 5:
        return _shortcutsPane(t);
      case 6:
        return _advancedPane(t);
      default:
        return _generalPane(t);
    }
  }

  // ---- panes -------------------------------------------------------------

  List<Widget> _generalPane(GlimprTokens t) {
    return [
      _h1(_l.settingsPaneGeneral, t),
      SectionLabel(_l.settingsSectionStartup, icon: Icons.power_settings_new),
      GlassCard.rows([
        SettingRow(
          title: _l.settingsLaunchAtLogin,
          hint: _l.settingsLaunchAtLoginHint,
          trailing: GlassToggle(
            value: _launchAtLogin,
            onChanged: (v) async {
              final actual = await LoginItem.setEnabled(v);
              if (mounted) setState(() => _launchAtLogin = actual);
            },
          ),
        ),
      ]),
      const SizedBox(height: 15),
      SectionLabel(_l.settingsLanguage, icon: Icons.translate),
      GlassCard.padded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _l.settingsLanguage,
              style: GlimprType.sansStyle(14.5, 600, t.fg1),
            ),
            const SizedBox(height: 4),
            Text(
              _l.settingsLanguageAppliesAfterRestart,
              style: GlimprType.sansStyle(12.5, 400, t.fg3),
            ),
            const SizedBox(height: 16),
            // The option names are proper nouns, shown as-is in both
            // localizations.
            Segmented<String>(
              full: true,
              value: _appLanguage,
              options: const [
                ('system', 'System'),
                ('en', 'English'),
                ('zh', '繁體中文'),
              ],
              onChanged: _setAppLanguage,
            ),
            if (_appLanguageInitial != null &&
                _appLanguage != _appLanguageInitial) ...[
              const SizedBox(height: 12),
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
                      _l.settingsRestartNotice,
                      style:
                          GlimprType.sansStyle(12.5, 600, GlimprTokens.danger),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ConfirmGhostButton(
                _l.settingsRestartNow,
                confirmLabel: _l.settingsRestartNowConfirm,
                onConfirmed: () => _roleChannel.invokeMethod('relaunch'),
              ),
            ],
          ],
        ),
      ),
    ];
  }

  /// Behaviour of the capture overlay itself (pointer, exit gestures, loupe,
  /// HUD) — everything about HOW a capture is taken.
  List<Widget> _capturePane(GlimprTokens t) {
    return [
      _h1(_l.settingsPaneCapture, t),
      SectionLabel(_l.settingsSectionBehaviour, icon: Icons.photo_camera_outlined),
      GlassCard.rows([
        SettingRow(
          title: _l.settingsMousePointer,
          hint: _l.settingsMousePointerHint,
          trailing: GlassToggle(
            value: _captureCursor,
            onChanged: (v) async {
              await _s.setCaptureCursor(v);
              if (mounted) setState(() => _captureCursor = v);
            },
          ),
        ),
        SettingRow(
          divider: true,
          title: _l.settingsRightClickExits,
          hint: _l.settingsRightClickExitsHint,
          trailing: GlassToggle(
            value: _rightClickExits,
            onChanged: (v) async {
              await _s.setRightClickExits(v);
              if (mounted) setState(() => _rightClickExits = v);
            },
          ),
        ),
        SettingRow(
          divider: true,
          title: _l.settingsConfirmBeforeDiscarding,
          hint: _l.settingsConfirmBeforeDiscardingHint,
          trailing: GlassToggle(
            value: _confirmOnExit,
            onChanged: (v) async {
              await _s.setConfirmOnExit(v);
              if (mounted) setState(() => _confirmOnExit = v);
            },
          ),
        ),
      ]),
      const SizedBox(height: 15),
      SectionLabel(_l.settingsSectionLoupe, icon: Icons.zoom_in),
      GlassCard.padded(child: _loupeBody(t)),
      const SizedBox(height: 8),
      GlassCard.rows([
        SettingRow(
          title: _l.settingsToolShortcutsWhileSampling,
          hint: _l.settingsToolShortcutsWhileSamplingHint,
          trailing: Segmented<bool>(
            value: _eyedropperKeysCancel,
            options: [(true, _l.settingsSwitchTool), (false, _l.settingsKeepSampling)],
            onChanged: (v) async {
              await _s.setEyedropperToolKeysCancel(v);
              if (mounted) setState(() => _eyedropperKeysCancel = v);
            },
          ),
        ),
      ]),
      const SizedBox(height: 15),
      SectionLabel(_l.settingsSectionOverlayHUD, icon: Icons.grid_goldenratio),
      GlassCard.rows([
        SettingRow(
          title: _l.settingsCrosshair,
          hint: _l.settingsCrosshairHint,
          trailing: GlassToggle(
            value: _hudCrosshair,
            onChanged: (v) async {
              await _s.setHudCrosshair(v);
              if (mounted) setState(() => _hudCrosshair = v);
            },
          ),
        ),
        SettingRow(
          divider: true,
          title: _l.settingsAnimateMarchingAnts,
          hint: _l.settingsAnimateMarchingAntsHint,
          trailing: GlassToggle(
            value: _hudMarchingAnts,
            onChanged: (v) async {
              await _s.setHudMarchingAnts(v);
              if (mounted) setState(() => _hudMarchingAnts = v);
            },
          ),
        ),
      ]),
    ];
  }

  /// Screen recording (macOS 15+ module): its own sidebar pane (owner
  /// request). Codec/fps under Format; cursor + audio under Behaviour; then
  /// the after-recording flow subset.
  List<Widget> _recordingPane(GlimprTokens t) {
    return [
      _h1(_l.settingsPaneRecording, t),
      if (!_recordAvailable)
        GlassCard.padded(
          child: Text(
            _l.settingsRecordingUnavailable,
            style: GlimprType.sansStyle(12.5, 400, t.fg3),
          ),
        )
      else ...[
        SectionLabel(_l.settingsSectionFormat, icon: Icons.movie_outlined),
        GlassCard.rows([
          SettingRow(
            title: _l.settingsRecordingFormat,
            hint: _l.settingsRecordingFormatHint,
            trailing: Segmented<RecordFormat>(
              value: _recordFormat,
              options: const [
                (RecordFormat.h264, 'H.264'),
                (RecordFormat.hevc, 'HEVC'),
                (RecordFormat.gif, 'GIF'),
              ],
              onChanged: (v) async {
                await _s.setRecordFormat(v);
                if (mounted) setState(() => _recordFormat = v);
              },
            ),
          ),
          SettingRow(
            divider: true,
            title: _l.settingsRecordingFps,
            hint: _l.settingsRecordingFpsHint,
            trailing: Segmented<int>(
              value: _recordFps,
              options: const [(30, '30 fps'), (60, '60 fps')],
              onChanged: (v) async {
                await _s.setRecordFps(v);
                if (mounted) setState(() => _recordFps = v);
              },
            ),
          ),
          SettingRow(
            divider: true,
            title: _l.settingsRecordingCountdown,
            hint: _l.settingsRecordingCountdownHint,
            trailing: Segmented<int>(
              value: _recordCountdown,
              options: [
                (0, _l.settingsRecordingDurationOff),
                for (final n in const [3, 5, 10])
                  (n, '$n${_l.settingsRecordingSecondsSuffix}'),
              ],
              onChanged: (v) async {
                await _s.setRecordCountdown(v);
                if (mounted) setState(() => _recordCountdown = v);
              },
            ),
          ),
          SettingRow(
            divider: true,
            title: _l.settingsRecordingMaxDuration,
            hint: _l.settingsRecordingMaxDurationHint,
            trailing: Segmented<int>(
              value: _recordMaxDuration,
              options: [
                (0, _l.settingsRecordingDurationOff),
                for (final n in const [5, 10, 15, 30, 60])
                  (n, '$n${_l.settingsRecordingSecondsSuffix}'),
              ],
              onChanged: (v) async {
                await _s.setRecordMaxDuration(v);
                if (mounted) setState(() => _recordMaxDuration = v);
              },
            ),
          ),
        ]),
        const SizedBox(height: 15),
        SectionLabel(_l.settingsSectionBehaviour,
            icon: Icons.videocam_outlined),
        GlassCard.rows([
          SettingRow(
            title: _l.settingsRecordingCursor,
            hint: _l.settingsRecordingCursorHint,
            trailing: GlassToggle(
              value: _recordShowCursor,
              onChanged: (v) async {
                await _s.setRecordShowCursor(v);
                if (mounted) setState(() => _recordShowCursor = v);
              },
            ),
          ),
          SettingRow(
            divider: true,
            title: _l.settingsRecordingSystemAudio,
            hint: _l.settingsRecordingSystemAudioHint,
            trailing: GlassToggle(
              value: _recordSystemAudio,
              onChanged: (v) async {
                await _s.setRecordSystemAudio(v);
                if (mounted) setState(() => _recordSystemAudio = v);
              },
            ),
          ),
          SettingRow(
            divider: true,
            title: _l.settingsRecordingMicrophone,
            hint: _l.settingsRecordingMicrophoneHint,
            trailing: GlassToggle(
              value: _recordMicrophone,
              onChanged: (v) async {
                await _s.setRecordMicrophone(v);
                if (mounted) setState(() => _recordMicrophone = v);
              },
            ),
          ),
        ]),
      ],
    ];
  }

  Widget _recordingFlowToggle(FlowAction a) => GlassToggle(
        value: _afterRecording.contains(a),
        onChanged: (v) async {
          final next = {..._afterRecording};
          v ? next.add(a) : next.remove(a);
          await _s.setAfterRecordingFlow(next);
          if (mounted) setState(() => _afterRecording = next);
        },
      );

  /// Completion flows + the sound feedback around them — what happens AFTER a
  /// capture / the editor's Done.
  List<Widget> _workflowPane(GlimprTokens t) {
    return [
      _h1(_l.settingsPaneWorkflow, t),
      SectionLabel(_l.settingsSectionAfterCapture, icon: Icons.layers_outlined),
      GlassCard.rows(_flowRows(capture: true)),
      _flowCaption(t, capture: true),
      const SizedBox(height: 15),
      // After-recording flow: lives HERE with its sibling completion flows
      // (Workflow = everything that runs when something finishes); the
      // Recording pane keeps only how a recording is made (format/behaviour).
      SectionLabel(_l.settingsSectionAfterRecording, icon: Icons.flag_outlined),
      if (!_recordAvailable)
        GlassCard.padded(
          child: Text(
            _l.settingsRecordingUnavailable,
            style: GlimprType.sansStyle(12.5, 400, t.fg3),
          ),
        )
      else
        GlassCard.rows([
          SettingRow(
            title: _l.settingsFlowCopyFilePath,
            hint: _l.settingsFlowCopyFilePathHint,
            trailing: _recordingFlowToggle(FlowAction.copyPath),
          ),
          SettingRow(
            divider: true,
            title: _l.settingsFlowShowInFinder,
            hint: _l.settingsFlowShowInFinderHint,
            trailing: _recordingFlowToggle(FlowAction.showInFinder),
          ),
          SettingRow(
            divider: true,
            title: _l.settingsFlowShareSheet,
            hint: _l.settingsFlowShareSheetHint,
            trailing: _recordingFlowToggle(FlowAction.shareSheet),
          ),
        ]),
      const SizedBox(height: 15),
      SectionLabel(_l.settingsSectionAfterEditorDone,
          icon: Icons.check_circle_outline),
      GlassCard.rows(_flowRows(capture: false)),
      _flowCaption(t, capture: false),
      const SizedBox(height: 15),
      SectionLabel(_l.settingsSectionSounds, icon: Icons.volume_up_outlined),
      GlassCard.rows([
        SettingRow(
          title: _l.settingsSoundShutter,
          hint: _l.settingsSoundShutterHint,
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
          title: _l.settingsSoundCompletion,
          hint: _l.settingsSoundCompletionHint,
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

  // The Loupe section body: a live preview that grows with the size, plus the
  // size + magnification sliders. The preview renders the REAL LoupePainter so
  // it is pixel-accurate to the in-capture loupe.
  Widget _loupeBody(GlimprTokens t) {
    final isDefault =
        _loupeSpan == kLoupeSpanDefault && _loupeZoom == kLoupeZoomDefault;
    // The loupe exceeds the preview frame, so the preview is shown scaled down
    // (not at its real on-screen size) — flagged next to Reset.
    final scaledPreview = _loupeSpan * _loupeZoom > _kLoupePreviewStage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _l.settingsLoupeDescription,
          style: GlimprType.sansStyle(12.5, 400, t.fg3),
        ),
        const SizedBox(height: 16),
        // Horizontal: live preview on the left, the controls on the right. Top-
        // aligned so the preview's top lines up with the Size label; the sliders
        // get full column width so their labels never wrap.
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _loupePreviewStage(t),
            const SizedBox(width: 24),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _loupeSlider(
                    t,
                    title: _l.settingsLoupeSize,
                    hint: _l.settingsLoupeSizeHint,
                    value: _loupeSpan,
                    min: kLoupeSpanMin,
                    max: kLoupeSpanMax,
                    suffix: ' px',
                    onChanged: (v) => setState(() => _loupeSpan = v),
                    onEnd: (v) => _s.setLoupeSpan(v),
                  ),
                  const SizedBox(height: 16),
                  _loupeSlider(
                    t,
                    title: _l.settingsLoupeMagnification,
                    hint: _l.settingsLoupeMagnificationHint,
                    value: _loupeZoom,
                    min: kLoupeZoomMin,
                    max: kLoupeZoomMax,
                    suffix: '×',
                    onChanged: (v) => setState(() => _loupeZoom = v),
                    onEnd: (v) => _s.setLoupeZoom(v),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      // Dark-grey note (only when the preview is scaled down):
                      // the preview is smaller than the real loupe, for display.
                      Expanded(
                        child: scaledPreview
                            ? Text(
                                _l.settingsLoupePreviewReduced,
                                style: GlimprType.sansStyle(11.5, 400, t.fg4),
                              )
                            : const SizedBox.shrink(),
                      ),
                      // Dimmed (disabled) at the defaults — same idiom as the
                      // per-shortcut Reset.
                      GhostButton(
                        _l.settingsLoupeReset,
                        onTap: isDefault ? null : _resetLoupe,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _resetLoupe() async {
    await _s.setLoupeSpan(kLoupeSpanDefault);
    await _s.setLoupeZoom(kLoupeZoomDefault);
    if (mounted) {
      setState(() {
        _loupeSpan = kLoupeSpanDefault;
        _loupeZoom = kLoupeZoomDefault;
      });
    }
  }

  // Compact fixed-size preview frame. The loupe is shown at its REAL size and
  // centred (so both sliders visibly change it and it is faithful), and only an
  // unusually large combo is scaled down to fit — never clipped. Fixed frame =
  // the surrounding UI never reflows while dragging.
  Widget _loupePreviewStage(GlimprTokens t) {
    const stage = _kLoupePreviewStage;
    final box = (_loupeSpan * _loupeZoom).toDouble();
    final Widget content = _LoupePreview(span: _loupeSpan, zoom: _loupeZoom);
    return Container(
      width: stage,
      height: stage,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: t.fg1.withValues(alpha: 0.04),
        border: Border.all(color: t.divider),
        borderRadius: BorderRadius.circular(12),
      ),
      child: box <= stage
          ? content // real on-screen size
          : FittedBox(fit: BoxFit.contain, child: content), // scaled down to fit
    );
  }

  // One control: title + hint above a full-width slider (which shows its own
  // value), so nothing is crammed into a narrow column and the label never wraps.
  Widget _loupeSlider(
    GlimprTokens t, {
    required String title,
    required String hint,
    required int value,
    required int min,
    required int max,
    required String suffix,
    required ValueChanged<int> onChanged,
    required ValueChanged<int> onEnd,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: GlimprType.sansStyle(13.5, 600, t.fg1)),
        const SizedBox(height: 2),
        Text(hint, style: GlimprType.sansStyle(12, 400, t.fg3)),
        const SizedBox(height: 6),
        GlimprSlider(
          value: value.toDouble(),
          min: min.toDouble(),
          max: max.toDouble(),
          suffix: suffix,
          onChanged: (v) => onChanged(v.round()),
          onChangeEnd: (v) => onEnd(v.round()),
        ),
      ],
    );
  }

  List<Widget> _outputPane(GlimprTokens t) {
    final lossy = _format == ImageFormat.jpeg;
    return [
      _h1(_l.settingsPaneOutput, t),
      SectionLabel(_l.settingsSectionSaveLocation, icon: Icons.folder_outlined),
      GlassCard.padded(child: _saveFolderBody(t)),
      const SizedBox(height: 15),
      SectionLabel(_l.settingsSectionFormat, icon: Icons.image_outlined),
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
                              _l.settingsFormatQuality,
                              style: GlimprType.sansStyle(14.5, 600, t.fg1),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _l.settingsFormatQualityHint,
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
      SectionLabel(_l.settingsSectionFilename, icon: Icons.text_fields_outlined),
      GlassCard.padded(child: _filenameBody(t)),
      const SizedBox(height: 15),
      SectionLabel(_l.settingsSectionDecoration, icon: Icons.filter_frames_outlined),
      GlassCard.rows([
        SettingRow(
          title: _l.settingsDecorationWindowSnap,
          hint: _l.settingsDecorationWindowSnapHint,
          trailing: GlassToggle(
            value: _decorateSnap,
            onChanged: (v) async {
              await _s.setDecorateSnap(v);
              if (mounted) setState(() => _decorateSnap = v);
            },
          ),
        ),
        SettingRow(
          divider: true,
          title: _l.settingsDecorationFreehandCrop,
          hint: _l.settingsDecorationFreehandCropHint,
          trailing: GlassToggle(
            value: _decorateCrop,
            onChanged: (v) async {
              await _s.setDecorateCrop(v);
              if (mounted) setState(() => _decorateCrop = v);
            },
          ),
        ),
        SettingRow(
          divider: true,
          title: _l.settingsDecorationFocusedWindow,
          hint: _l.settingsDecorationFocusedWindowHint,
          trailing: GlassToggle(
            value: _decorateWindow,
            onChanged: (v) async {
              await _s.setDecorateWindow(v);
              if (mounted) setState(() => _decorateWindow = v);
            },
          ),
        ),
        SettingRow(
          divider: true,
          title: _l.settingsDecorationDisplay,
          hint: _l.settingsDecorationDisplayHint,
          trailing: GlassToggle(
            value: _decorateDisplay,
            onChanged: (v) async {
              await _s.setDecorateDisplay(v);
              if (mounted) setState(() => _decorateDisplay = v);
            },
          ),
        ),
        SettingRow(
          divider: true,
          title: _l.settingsDecorationLastRegion,
          hint: _l.settingsDecorationLastRegionHint,
          trailing: GlassToggle(
            value: _decorateLastRegion,
            onChanged: (v) async {
              await _s.setDecorateLastRegion(v);
              if (mounted) setState(() => _decorateLastRegion = v);
            },
          ),
        ),
        SettingRow(
          divider: true,
          title: _l.settingsDecorationJpegFill,
          hint: _l.settingsDecorationJpegFillHint,
          trailing: _DecorationFillSwatch(
            argb: _decorationJpegFill,
            onChanged: (argb) async {
              await _s.setDecorationJpegFill(argb);
              if (mounted) setState(() => _decorationJpegFill = argb);
            },
          ),
        ),
      ]),
      const SizedBox(height: 8),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          _l.settingsDecorationPinNote,
          style: GlimprType.sansStyle(12, 400, t.fg4),
        ),
      ),
      const SizedBox(height: 15),
      SectionLabel(_l.settingsSectionRecentHistory, icon: Icons.history),
      GlassCard.padded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _l.settingsRecentImagesKept,
              style: GlimprType.sansStyle(14.5, 600, t.fg1),
            ),
            const SizedBox(height: 4),
            Text(
              _l.settingsRecentImagesKeptHint,
              style: GlimprType.sansStyle(12.5, 400, t.fg3),
            ),
            const SizedBox(height: 16),
            // All presets are 5k-1 so the trailing More… tile always closes
            // the grid as a full rectangle at the minimum window width.
            Segmented<int>(
              full: true,
              value: const [19, 44, 69, 99].contains(_recentCap)
                  ? _recentCap
                  : kRecentImagesCap,
              options: const [(19, '19'), (44, '44'), (69, '69'), (99, '99')],
              onChanged: (v) async {
                await RecentImagesStore.setCap(_s.store, v);
                if (mounted) setState(() => _recentCap = v);
              },
            ),
          ],
        ),
      ),
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
            Text(_l.settingsFilenamePreview, style: GlimprType.sansStyle(12.5, 600, t.fg4)),
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
        Text(_l.settingsFilenamePlaceholders, style: GlimprType.sansStyle(12.5, 600, t.fg4)),
        const SizedBox(height: 8),
        _token(t, '{window}', _l.settingsFilenameTokenWindowDesc),
        _token(t, '{app}', _l.settingsFilenameTokenAppDesc),
        _token(t, '{date}', _l.settingsFilenameTokenDateDesc),
        _token(t, '{time}', _l.settingsFilenameTokenTimeDesc),
        const SizedBox(height: 6),
        Text(
          _l.settingsFilenameNote('{window}', '{app}'),
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

  List<Widget> _advancedPane(GlimprTokens t) {
    return [
      _h1(_l.settingsPaneAdvanced, t),
      SectionLabel(_l.settingsSectionMultiDisplay, icon: Icons.memory),
      GlassCard.padded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _l.settingsWarmEnginesTitle,
              style: GlimprType.sansStyle(14.5, 600, t.fg1),
            ),
            const SizedBox(height: 4),
            Text(
              _l.settingsWarmEnginesBody,
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
            if (_warmTargetInitial != null && _warmTarget != _warmTargetInitial) ...[
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
                      _l.settingsRestartNotice,
                      style: GlimprType.sansStyle(12.5, 600, GlimprTokens.danger),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // One click instead of quit-from-the-menu-bar + reopen: the native
              // side re-opens the bundle after this process exits. Two-step
              // (arm -> confirm) because it kills the running app.
              ConfirmGhostButton(
                _l.settingsRestartNow,
                confirmLabel: _l.settingsRestartNowConfirm,
                onConfirmed: () => _roleChannel.invokeMethod('relaunch'),
              ),
            ] else
              Text(
                _l.settingsWarmEnginesDefault,
                style: GlimprType.sansStyle(12, 500, t.fg4),
              ),
          ],
        ),
      ),
      const SizedBox(height: 15),
      SectionLabel(_l.settingsSectionCaptureLayers, icon: Icons.layers_outlined),
      GlassCard.padded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _l.settingsCaptureLayersTitle,
              style: GlimprType.sansStyle(14.5, 600, t.fg1),
            ),
            const SizedBox(height: 4),
            Text(
              _l.settingsCaptureLayersBody,
              style: GlimprType.sansStyle(12.5, 400, t.fg3),
            ),
            const SizedBox(height: 16),
            Segmented<int>(
              full: true,
              value: _captureLayerCap.clamp(1, 5),
              options: const [(1, '1'), (2, '2'), (3, '3'), (4, '4'), (5, '5')],
              onChanged: _setCaptureLayerCap,
            ),
          ],
        ),
      ),
      const SizedBox(height: 15),
      SectionLabel(_l.settingsSectionToolStyles, icon: Icons.brush_outlined),
      GlassCard.padded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_l.settingsResetAllToolStyles,
                style: GlimprType.sansStyle(14.5, 600, t.fg1)),
            const SizedBox(height: 4),
            Text(
              _l.settingsResetAllToolStylesHint,
              style: GlimprType.sansStyle(12.5, 400, t.fg3),
            ),
            const SizedBox(height: 14),
            // Two-step confirm: wipes EVERY tool's saved style, unrecoverable.
            ConfirmGhostButton(
              _l.settingsResetAllToolStyles,
              confirmLabel: _l.settingsResetAllToolStylesConfirm,
              onConfirmed: () {
                ToolStyleStore(Settings.instance.store).resetAll();
              },
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
      _h1(_l.settingsPaneShortcuts, t),
      SectionLabel(_l.settingsPaneCapture, icon: Icons.crop_free,
          note: _l.settingsShortcutsCaptureNote),
      GlassCard.rows([
        for (final a in kGlobalActions)
          if (!kRecordActionKeys.contains(a.actionKey))
            SettingRow(
              title: globalActionLabel(_l, a.actionKey),
              hint: globalActionHint(_l, a.actionKey),
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
      SectionLabel(_l.settingsSectionRecording, icon: Icons.videocam_outlined),
      GlassCard.rows([
        for (final a in kGlobalActions)
          if (kRecordActionKeys.contains(a.actionKey))
            SettingRow(
              title: globalActionLabel(_l, a.actionKey),
              hint: globalActionHint(_l, a.actionKey),
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
      // Tools — tool-selection keys (rebindable), in toolbar order.
      SectionLabel(_l.settingsShortcutsTools, icon: Icons.palette_outlined),
      GlassCard.rows([
        for (final (tool, icon) in kEditorToolMeta)
          SettingRow(
            // Shared with the toolbar tooltips (tool_meta) — never drifts.
            title: toolSettingsLabel(_l, tool),
            icon: icon,
            // The crop slot's one binding drives crop AND the pin-mode pin
            // selector: crop keeps the standard 18px glyph (row rhythm) and
            // the pin rides its corner as a small badge — the toolbar's
            // shortcut-badge language, crisp-outlined to separate the glyphs.
            iconWidget: tool == ToolKind.crop
                ? _CropPinGlyph(t: t)
                : null,
            trailing: _bindingRow(
              t: t,
              actionKey: kEditorToolActionKey[tool]!,
              requireModifier: false,
              reserved: kEditorReservedKeys,
              dupes: dupes,
            ),
          ),
      ]),
      const SizedBox(height: 24),
      // Commands — annotation / document commands (rebindable).
      SectionLabel(_l.settingsShortcutsCommands, icon: Icons.edit_outlined),
      GlassCard.rows([
        for (final cmd in <(String, String, String?)>[
          (kEditorUndoKey, _l.settingsCmdUndo, null),
          (kEditorRedoKey, _l.settingsCmdRedo, null),
          (kEditorPasteKey, _l.settingsCmdPasteImage, _l.settingsCmdPasteImageHint),
          (kEditorDeleteKey, _l.settingsCmdDeleteSelected, _l.settingsCmdDeleteSelectedHint),
          (
            kEditorConfirmKey,
            _l.settingsCmdExport,
            _l.settingsCmdExportHint,
          ),
          (kEditorDuplicateKey, _l.settingsCmdDuplicateSelected, _l.settingsCmdDuplicateSelectedHint),
          (
            kEditorBringToFrontKey,
            _l.settingsCmdBringToFront,
            _l.settingsCmdBringToFrontHint,
          ),
          (kEditorSendToBackKey, _l.settingsCmdSendToBack, _l.settingsCmdSendToBackHint),
          (
            kEditorCopyHexKey,
            _l.settingsCmdCopyHex,
            _l.settingsCmdCopyColorHint,
          ),
          (
            kEditorCopyRgbKey,
            _l.settingsCmdCopyRgb,
            _l.settingsCmdCopyColorHint,
          ),
          (
            kEditorCopyHslKey,
            _l.settingsCmdCopyHsl,
            _l.settingsCmdCopyColorHint,
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
      ]),
      const SizedBox(height: 24),
      // Reserved — fixed keys that cannot be rebound (the per-row hint notes the
      // surface each applies to). Rendered in a field-shaped box matching the
      // recorder so the caps line up with the editable rows (a lock glyph
      // replaces the recorder's keyboard/✕ glyph).
      SectionLabel(_l.settingsShortcutsReserved, icon: Icons.lock_outline),
      GlassCard.rows([
        SettingRow(
          title: _l.settingsReservedCancelExit,
          hint: _l.settingsReservedHint,
          trailing: _reservedField(t, const [KeyCap('esc')]),
        ),
        SettingRow(
          title: _l.settingsReservedCloseWindow,
          hint: _l.settingsReservedHintEditorSettings,
          trailing: _reservedField(t, const [KeyCap('⌘'), KeyCap('W')]),
        ),
        SettingRow(
          title: _l.settingsReservedOpenSettings,
          hint: _l.settingsReservedHintOverlayEditor,
          trailing: _reservedField(t, const [KeyCap('⌘'), KeyCap(',')]),
        ),
        SettingRow(
          title: _l.settingsReservedNudgeCrosshair,
          hint: _l.settingsReservedHintRegionTools,
          trailing: _reservedField(
            t,
            const [KeyCap('←'), KeyCap('↑'), KeyCap('↓'), KeyCap('→')],
          ),
        ),
        // Image-editor viewport zoom — fixed keys (the capture overlay is 1:1).
        SettingRow(
          title: _l.settingsReservedFitToWindow,
          hint: _l.settingsReservedHintImageEditor,
          trailing: _reservedField(t, const [KeyCap('⌘'), KeyCap('1')]),
        ),
        SettingRow(
          title: _l.settingsReservedZoomTo100,
          hint: _l.settingsReservedHintImageEditor,
          trailing: _reservedField(t, const [KeyCap('⌘'), KeyCap('2')]),
        ),
        // Text-input semantics, fixed while editing a text annotation — one row
        // per action so the keys don't read as a single chord.
        SettingRow(
          title: _l.settingsReservedCommitText,
          hint: _l.settingsReservedHintWhileEditingText,
          trailing: _reservedField(t, const [KeyCap('⏎')]),
        ),
        SettingRow(
          title: _l.settingsReservedNewLine,
          hint: _l.settingsReservedHintWhileEditingText,
          trailing: _reservedField(t, const [KeyCap('⇧'), KeyCap('⏎')]),
        ),
        SettingRow(
          title: _l.settingsReservedCancelText,
          hint: _l.settingsReservedHintWhileEditingText,
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
          GhostButton(_l.settingsShortcutsRevert, onTap: _revertShortcuts),
          const SizedBox(width: 8),
          if (allValid)
            AccentButton(_l.settingsShortcutsApply, onTap: _applyShortcuts)
          else
            GhostButton(_l.settingsShortcutsApply, onTap: null),
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
        ? _l.settingsShortcutsNeedsModifier
        : (isDupe ? _l.settingsShortcutsDuplicate : null);
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
          onRecordingChanged: _onRecordingChanged,
        ),
        const SizedBox(width: 4),
        // Reset to default — disabled + dimmed when the binding already is the
        // default (nothing to reset), so it reads as inactive.
        Opacity(
          opacity: isDefault ? 0.25 : 1,
          child: IconButton(
            tooltip: isDefault ? null : _l.settingsShortcutsResetToDefault,
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
                _l.settingsSaveFolder,
                style: GlimprType.sansStyle(14.5, 600, t.fg1),
              ),
            ),
            const SizedBox(width: 14),
            AccentButton(
              _l.settingsSaveFolderChoose,
              icon: Icons.folder_open_outlined,
              onTap: _chooseDir,
            ),
            const SizedBox(width: 8),
            GhostButton(_l.settingsSaveFolderReset, onTap: path == null ? null : _resetDir),
          ],
        ),
        const SizedBox(height: 10),
        if (path == null)
          Text(_l.settingsSaveFolderDefault, style: mono)
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

/// JPEG background-fill picker: a compact row of preset opaque swatches. The fill
/// only applies to decorated JPEG output (PNG keeps its transparency). Kept to a
/// small palette by design — a free colour picker can be added if needed.
class _DecorationFillSwatch extends StatelessWidget {
  final int argb;
  final ValueChanged<int> onChanged;
  const _DecorationFillSwatch({required this.argb, required this.onChanged});

  static const _palette = <int>[
    0xFFFFFFFF, // white
    0xFFE2E5E9, // light grey
    0xFF808080, // mid grey
    0xFF202327, // dark grey
    0xFF000000, // black
  ];

  @override
  Widget build(BuildContext context) {
    final t = GlimprTheme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < _palette.length; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          GestureDetector(
            onTap: () => onChanged(_palette[i]),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: Color(_palette[i]),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: argb == _palette[i]
                        ? GlimprTokens.accent
                        : t.divider,
                    width: argb == _palette[i] ? 2 : 1,
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Live, pixel-accurate loupe preview for the settings pane. Renders the real
/// [LoupePainter] over a fixed synthetic sample so changing the size /
/// magnification sliders shows exactly what the in-capture loupe will look like.
/// The on-screen box is span * zoom, so it grows with the size (model B).
class _LoupePreview extends StatefulWidget {
  final int span;
  final int zoom;
  const _LoupePreview({required this.span, required this.zoom});

  @override
  State<_LoupePreview> createState() => _LoupePreviewState();
}

class _LoupePreviewState extends State<_LoupePreview> {
  ui.Image? _sample;

  // Sample size in native px — must exceed the largest span (20) so the loupe's
  // centered window always lands inside the image.
  static const int _n = 40;

  @override
  void initState() {
    super.initState();
    _buildSample();
  }

  Future<void> _buildSample() async {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    // Dark glass tile (matching the app icon) so the gradient mark pops.
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 40, 40),
      Paint()
        ..shader = ui.Gradient.linear(
          const Offset(0, 0),
          const Offset(0, 40),
          const [Color(0xFF1B2138), Color(0xFF0A0E1A)],
        ),
    );
    // Our Viewfinder logo as the loupe subject: magnified, it shows the brand
    // mark's gradient + crisp bracket / spark edges as clean pixels. The loupe
    // centres on the spark, so smaller sizes zoom into it and larger sizes
    // reveal the surrounding brackets.
    paintGlimprMark(canvas, const Size(40, 40));
    final pic = rec.endRecording();
    final img = await pic.toImage(_n, _n);
    pic.dispose();
    if (!mounted) {
      img.dispose();
      return;
    }
    setState(() => _sample = img);
  }

  @override
  void dispose() {
    _sample?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final box = (widget.span * widget.zoom).toDouble();
    final img = _sample;
    if (img == null) return SizedBox(width: box, height: box);
    return CustomPaint(
      size: Size(box, box),
      painter: LoupePainter(
        image: img,
        cursorLogical: const Offset(_n / 2, _n / 2),
        scaleFactor: 1,
        zoom: widget.zoom.toDouble(),
      ),
    );
  }
}

/// The Crop / Pin / Record row's glyph: the standard 18px crop icon with a
/// small pin badge riding its bottom-right corner and a small videocam badge
/// at its top-right — the toolbar's shortcut-badge language, one badge per
/// alternate context. The crisp zero-blur outline (8 offsets, toolbar
/// badgeOutline colors) separates the badges from the crop strokes.
class _CropPinGlyph extends StatelessWidget {
  const _CropPinGlyph({required this.t});
  final GlimprTokens t;

  @override
  Widget build(BuildContext context) {
    final outline =
        t.isDark ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(Icons.crop, size: 18, color: t.accentFg),
        Positioned(
          right: -4,
          top: -3,
          child: Icon(
            Icons.videocam,
            size: 11,
            color: t.accentFg,
            shadows: [
              for (final o in const [
                Offset(0.7, 0),
                Offset(-0.7, 0),
                Offset(0, 0.7),
                Offset(0, -0.7),
                Offset(0.7, 0.7),
                Offset(0.7, -0.7),
                Offset(-0.7, 0.7),
                Offset(-0.7, -0.7),
              ])
                Shadow(color: outline, offset: o),
            ],
          ),
        ),
        Positioned(
          right: -4,
          bottom: -3,
          child: Icon(
            Icons.push_pin,
            size: 11,
            color: t.accentFg,
            shadows: [
              for (final o in const [
                Offset(0.7, 0),
                Offset(-0.7, 0),
                Offset(0, 0.7),
                Offset(0, -0.7),
                Offset(0.7, 0.7),
                Offset(0.7, -0.7),
                Offset(-0.7, 0.7),
                Offset(-0.7, -0.7),
              ])
                Shadow(color: outline, offset: o),
            ],
          ),
        ),
      ],
    );
  }
}
