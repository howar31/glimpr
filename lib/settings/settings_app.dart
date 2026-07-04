import 'dart:io' show Platform;
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:simple_icons/simple_icons.dart';

import 'licenses_page.dart';
import '../editor/editor_controller.dart' show ToolKind;
import '../editor/loupe_config.dart';
import '../l10n/gen/app_localizations.dart';
import 'app_locale.dart';
import '../editor/tool_meta.dart';
import '../overlay/crop_hud.dart';
import '../capture/capture_bridge.dart';
import '../capture/direct_capture.dart'
    show
        kDisplayCaptureLabel,
        kLastRegionCaptureLabel,
        kRecordingCaptureLabel;
import '../output/deliver.dart';
import '../output/filename.dart';
import '../output/name_tokens.dart';
import '../output/flow.dart';
import '../record/record_bridge.dart';
import '../shortcuts/hotkey_binding.dart';
import '../shortcuts/hotkey_registrar.dart';
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
import 'token_picker.dart';

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

// Reserved at the top for the transparent title bar / traffic lights (macOS
// frameless .fullSizeContentView). Windows has a standard OS caption above the
// client area, so it only needs a small breathing inset, not the traffic-light
// clearance.
double get _titleBarInset => GlimprTokens.titleBarInset;

// Side of the square Loupe preview frame. A loupe larger than this is scaled
// down to fit (and flagged), so the section never reflows while dragging.
const double _kLoupePreviewStage = 200;

// Sidebar order follows the user's pipeline: how to capture -> what gets
// produced (and where) -> what happens on completion; General keeps the
// app-level items, Advanced the expert/danger zone. Icons only; the displayed
// titles are localized in _sectionTitle (same order).
const _kSections = <IconData>[
  Icons.tune, // General
  Icons.photo_camera_outlined, // Screenshot
  Icons.videocam_outlined, // Recording
  Icons.brush_outlined, // Image Editor
  Icons.center_focus_strong_outlined, // Selection & HUD
  Icons.folder_outlined, // Output
  Icons.keyboard, // Shortcuts
  Icons.memory, // Advanced
  Icons.info_outline, // About
];

// The About pane's section index (last entry of [_kSections]).
const int _kAboutSection = 8;

class _SettingsAppState extends State<SettingsApp>
    with WidgetsBindingObserver {
  // Resolved once per build frame inside the MaterialApp's localizations scope
  // (set in the Builder in build()). Using a field instead of a context-arg
  // avoids threading BuildContext through every helper method.
  late AppLocalizations _l;

  // A context INSIDE the MaterialApp (below its Navigator), captured each build
  // alongside [_l]. The State's own `context` sits ABOVE the MaterialApp, so
  // routes pushed from there (e.g. showLicensePage) find no Navigator.
  BuildContext? _pageContext;

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
  bool _hdrScreenshot = false;
  bool _pinHoverGlow = true;
  bool _launchAtLogin = false;
  int _warmTarget = 2;
  int _recentCap = kRecentImagesCap;
  int _captureLayerCap = 1;
  // Precise AX element snap (Advanced experiment) + the live Accessibility
  // permission state (re-checked on load + while the grant prompt is pending).
  bool _snapElementMode = false;
  bool _axTrusted = false;
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
  RecordVideoQuality _recordVideoQuality = RecordVideoQuality.high;
  int _recordMaxLongSide = 1920;
  int _recordGifFps = 15;
  int _recordCountdown = 0;
  int _recordMaxDuration = 0;
  bool _recordShowCursor = true;
  bool _recordScrim = true;
  bool _recordSystemAudio = false;
  bool _recordMicrophone = false;
  bool _recordMergeAudio = false;
  Set<FlowAction> _afterRecording = {};
  int _loupeSpan = kLoupeSpanDefault;
  int _loupeZoom = kLoupeZoomDefault;
  bool _eyedropperKeysCancel = true;
  bool _hudCrosshair = true;
  bool _hudLoupe = true;
  bool _hudMarchingAnts = true;
  final _filenameController = TextEditingController();
  final _filenameFocus = FocusNode();
  String _subfolderPattern = defaultSubfolderPattern;
  final _subfolderController = TextEditingController();
  final _subfolderFocus = FocusNode();
  // The Output pane is STAGED like Shortcuts: edits update the draft state
  // (_saveDir / _filenameTemplate / _subfolderPattern) but persist only on
  // Apply, which also normalizes the patterns and fills an empty field with its
  // default. These baselines are the last-applied values; dirty = draft != base.
  String? _savedSaveDir;
  String _savedFilename = defaultFilenameTemplate;
  String _savedSubfolder = defaultSubfolderPattern;
  // On blur, a pattern field flags (without modifying) when it holds reserved
  // characters that Apply would strip — a heads-up; Apply does the rewrite.
  bool _filenameWarn = false;
  bool _subfolderWarn = false;

  // Shortcuts draft: null until the user first opens the Shortcuts pane. Only
  // this pane uses a staged draft (the other panes are live-apply). The baseline
  // is the last-applied state; Revert restores it and the Apply/Revert buttons
  // show only when the draft differs from it.
  late final _shortcutStore = ShortcutStore(widget.settings.store);
  Map<String, HotkeyBinding?>? _shortcutsDraft;
  Map<String, HotkeyBinding?> _shortcutsBaseline = const {};
  // Actions whose CURRENT DRAFT combo is reserved / already taken by another app
  // (a record-time probe on Windows said unavailable, or seeded from a boot
  // conflict). Treated like a duplicate: the row warns and Apply is blocked, so
  // an unusable binding can't be saved.
  final Set<String> _inUseActions = {};
  // The same, but for the BASELINE (last-applied) bindings — boot conflicts that
  // still apply. Revert restores _inUseActions from this (so a still-valid error
  // isn't wiped); a successful Apply clears it (the applied state is conflict-free).
  Set<String> _baselineInUse = {};
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
    _filenameFocus.addListener(_onPatternFocusChange);
    _subfolderFocus.addListener(_onPatternFocusChange);
    // Native → Dart pushes on the role channel (menu-bar "About Glimpr" deep-link).
    _roleChannel.setMethodCallHandler(_onRoleCall);
    _load();
  }

  // Handle native-initiated role-channel calls (Dart→native still uses
  // invokeMethod separately; a MethodChannel is bidirectional).
  Future<dynamic> _onRoleCall(MethodCall call) async {
    if (call.method == 'showAbout' && mounted) {
      setState(() => _section = _kAboutSection);
    }
    return null;
  }

  // The app's marketing + build version, read once from the native bundle.
  // Degrades to '' when the native role channel is absent (e.g. Windows before
  // the resident-shell native layer exists), so the About pane renders blank
  // instead of surfacing an unhandled MissingPluginException.
  late final Future<String> _appVersionFuture = _loadAppVersion();

  Future<String> _loadAppVersion() async {
    try {
      return await _roleChannel.invokeMethod<String>('appVersion') ?? '';
    } catch (_) {
      return '';
    }
  }

  void _openUrl(String url) =>
      _roleChannel.invokeMethod('openExternalUrl', {'url': url});

  // On focus change, re-flag each pattern field: warn (don't modify) when it has
  // lost focus AND holds reserved characters Apply would strip. A filename can't
  // span folders, so separators count as reserved there; the subfolder keeps
  // them (structural). Clears while the field is focused (mid-edit).
  void _onPatternFocusChange() {
    setState(() {
      _filenameWarn = !_filenameFocus.hasFocus &&
          RegExp(r'[/\\:*?"<>|\x00-\x1f]').hasMatch(_filenameTemplate);
      _subfolderWarn = !_subfolderFocus.hasFocus &&
          RegExp(r'[:*?"<>|\x00-\x1f]').hasMatch(_subfolderPattern);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _filenameController.dispose();
    _filenameFocus.dispose();
    _subfolderController.dispose();
    _subfolderFocus.dispose();
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
    final subfolder = await _s.getSubfolderPattern();
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
    final hudLoupe = await _s.getHudLoupe();
    final hudMarchingAnts = await _s.getHudMarchingAnts();
    final layerCap = await _s.getCaptureLayerCap();
    final snapElementMode = await _s.getSnapElementMode();
    final hdrScreenshot = await _s.getHdrScreenshot();
    final appLanguage = await _s.getAppLanguage();
    final pinHoverGlow = await _s.getPinHoverGlow();
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
      _pinHoverGlow = pinHoverGlow;
      _filenameTemplate = template;
      _subfolderPattern = subfolder;
      _savedSaveDir = dir;
      _savedFilename = template;
      _savedSubfolder = subfolder;
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
      _hudLoupe = hudLoupe;
      _hudMarchingAnts = hudMarchingAnts;
      _captureLayerCap = layerCap;
      _snapElementMode = snapElementMode;
      _hdrScreenshot = hdrScreenshot;
      _appLanguage = appLanguage;
      _appLanguageInitial = appLanguage;
      _recordFormat = rec.format;
      _recordFps = rec.fps;
      _recordVideoQuality = rec.videoQuality;
      _recordMaxLongSide = rec.maxLongSide;
      _recordGifFps = rec.gifFps;
      _recordCountdown = rec.countdown;
      _recordMaxDuration = rec.maxDuration;
      _recordShowCursor = rec.showCursor;
      _recordScrim = rec.scrim;
      _recordSystemAudio = rec.systemAudio;
      _recordMicrophone = rec.microphone;
      _recordMergeAudio = rec.mergeAudio;
      _afterRecording = rec.flow;
    });
    _filenameController.text = template;
    _subfolderController.text = subfolder;
    // Recording availability is a native (macOS version) fact; guard so an
    // unmocked channel never breaks the rest of the UI (widget tests).
    final recordAvailable = await RecordBridge().isAvailable();
    if (mounted) setState(() => _recordAvailable = recordAvailable);
    // AX permission is a native fact (element-snap status row); query it
    // separately for the same reason (unmocked channel in widget tests).
    _refreshAxTrusted();
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

  /// Toggle one action in a completion flow and persist it. The transition
  /// rules (copy/copyPath exclusivity, save cascading its dependents off) live
  /// in [toggleFlowAction].
  Future<void> _setFlowAction({
    required bool capture,
    required FlowAction action,
    required bool on,
  }) async {
    final next = toggleFlowAction(
        capture ? _afterCapture : _afterEditorDone, action, on);
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
        title: Platform.isWindows
            ? _l.settingsFlowShowInFinderWin
            : _l.settingsFlowShowInFinder,
        hint: hasSave
            ? (Platform.isWindows
                ? _l.settingsFlowShowInFinderHintWin
                : _l.settingsFlowShowInFinderHint)
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
      // Share is macOS-only (no system share surface wired on Windows v1).
      if (!Platform.isWindows)
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

  /// A muted caption UNDER a section's card (full width, wraps) — for section
  /// explanations that are too long to sit beside the title without truncating.
  Widget _sectionNote(GlimprTokens t, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
        child: Text(text,
            style: GlimprType.sansStyle(12, 500, t.fg4, height: 1.4)),
      );

  // Every scope chip on the Shortcuts page shares one width — the widest of the
  // five localized labels — so the chips (and the title indent past them) line
  // up across rows. Recomputed per build (cheap: 5 measurements); set at the top
  // of _shortcutsPane before any chip is built.
  double _scopeChipW = 0;
  double _computeScopeChipWidth() {
    final style =
        GlimprType.sansStyle(10.5, 600, const Color(0xFF000000), letterSpacing: 0.2);
    var w = 0.0;
    for (final s in [
      _l.scopeGlobal,
      _l.scopeEditor,
      _l.scopeOverlay,
      _l.scopeImage,
      _l.scopeText,
    ]) {
      final tp = TextPainter(
        text: TextSpan(text: s, style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      if (tp.width > w) w = tp.width;
    }
    return w + 13; // 6 + 6 horizontal padding, + 1 rounding slack
  }

  Widget _scopeChip(String label) => ScopeTag(label, width: _scopeChipW);

  // One legend row: the scope chip in a fixed-width column so the glosses line
  // up, then its description.
  Widget _legendRow(GlimprTokens t, String tag, String desc) => Padding(
        padding: const EdgeInsets.only(top: 7),
        child: Row(
          children: [
            SizedBox(
              width: 68,
              child: Align(
                alignment: Alignment.centerLeft,
                child: _scopeChip(tag),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(desc,
                  style: GlimprType.sansStyle(12.5, 500, t.fg2, height: 1.3)),
            ),
          ],
        ),
      );

  // Shortcuts-pane legend: the page-wide uniqueness rule + what each scope chip
  // means, shown above the first section. A bordered panel (NOT a GlassCard) so
  // it stays visually distinct from the binding cards.
  Widget _shortcutsLegend(GlimprTokens t) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          border: Border.all(color: t.divider),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _l.shortcutsLegendDedup,
              style: GlimprType.sansStyle(12.5, 500, t.fg3, height: 1.45),
            ),
            const SizedBox(height: 6),
            _legendRow(t, _l.scopeGlobal, _l.scopeGlobalDesc),
            _legendRow(t, _l.scopeEditor, _l.scopeEditorDesc),
            _legendRow(t, _l.scopeOverlay, _l.scopeOverlayDesc),
            _legendRow(t, _l.scopeImage, _l.scopeImageDesc),
            _legendRow(t, _l.scopeText, _l.scopeTextDesc),
          ],
        ),
      );

  // Staged: update the draft only; Apply persists (see _applyOutput).
  Future<void> _chooseDir() async {
    final picked = await getDirectoryPath();
    if (picked == null) return;
    if (mounted) setState(() => _saveDir = picked);
  }

  void _resetDir() => setState(() => _saveDir = null);

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

  Future<void> _setSnapElementMode(bool v) async {
    setState(() => _snapElementMode = v);
    await _s.setSnapElementMode(v);
    // Turning it on without permission prompts for it; then poll so the status
    // row flips live once the user grants in System Settings.
    if (v && !_axTrusted) {
      await CaptureBridge().requestAccessibility();
      _recheckAxTrusted();
    }
  }

  /// One-shot AX permission check (off the critical load path so an unmocked
  /// channel never stalls widget tests).
  Future<void> _refreshAxTrusted() async {
    final t = await CaptureBridge().accessibilityTrusted();
    if (!mounted || t == _axTrusted) return;
    setState(() => _axTrusted = t);
  }

  /// Poll the AX permission for a short window so the status row updates after
  /// the user grants it in the system prompt / System Settings (no app restart).
  Future<void> _recheckAxTrusted() async {
    for (var i = 0; i < 12; i++) {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return;
      final t = await CaptureBridge().accessibilityTrusted();
      if (!mounted) return;
      if (t != _axTrusted) setState(() => _axTrusted = t);
      if (t) return;
    }
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
        // Windows paints the opaque themed base (no native glass behind the
        // view — transparent base pixels composite BLACK on the raw engine
        // surface, which only LOOKS right under the dark palette). macOS stays
        // pure vibrancy (transparent over NSVisualEffectView).
        child: ColoredBox(
          color: Platform.isWindows ? tokens.winBase : Colors.transparent,
          child: CallbackShortcuts(
          bindings: {
            // Close the Settings window: Ctrl+W on Windows, Cmd-W on macOS.
            // (meta = the Win key on Windows, and Win+W is a reserved system
            // shortcut that never reaches the app, so Windows binds Ctrl+W.)
            SingleActivator(LogicalKeyboardKey.keyW,
                meta: !Platform.isWindows, control: Platform.isWindows): _close,
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
                  _pageContext = ctx; // below the Navigator (for showLicensePage)
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
      ),
    );
  }

  // ---- sidebar -----------------------------------------------------------

  // Maps section index to the localized pane title. Must stay in sync with
  // _kSections order and _pane()'s switch.
  String _sectionTitle(int i) {
    switch (i) {
      case 1: return _l.settingsPaneCapture; // Screenshot
      case 2: return _l.settingsPaneRecording;
      case 3: return _l.settingsPaneImageEditor;
      case 4: return _l.settingsPaneSelectionHud;
      case 5: return _l.settingsPaneOutput;
      case 6: return _l.settingsPaneShortcuts;
      case 7: return _l.settingsPaneAdvanced;
      case 8: return _l.settingsPaneAbout;
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
          // Traffic-light zone (real macOS controls overlay this area); a small
          // breathing inset on Windows (the OS caption is above the client area).
          SizedBox(height: _titleBarInset),
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
                      icon: _kSections[i],
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
            // The real bundle version (same source as the About pane), so the
            // caption can never go stale on a version bump. The About pane
            // shows the full "x.y.z (build)"; the sidebar keeps just x.y.z.
            child: FutureBuilder<String>(
              future: _appVersionFuture,
              builder: (_, snap) {
                final v = (snap.data ?? '').split(' ').first;
                return Text(
                  v.isEmpty ? 'Glimpr' : 'Glimpr $v',
                  style: GlimprType.sansStyle(11.5, 500, t.fg4),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ---- content -----------------------------------------------------------

  Widget _content(GlimprTokens t) {
    final list = ListView(
      padding: EdgeInsets.fromLTRB(28, _titleBarInset, 28, 32),
      children: [
        ..._pane(t),
      ],
    );
    // The Shortcuts pane is long; pin its Apply/Revert bar to the bottom so it's
    // always reachable without scrolling to the end of the list.
    if (_section == 6) {
      return Column(
        children: [Expanded(child: list), _shortcutsFooter(t)],
      );
    }
    // The Output pane is staged too: pin its Apply/Revert bar like Shortcuts.
    if (_section == 5) {
      return Column(
        children: [Expanded(child: list), _outputFooter(t)],
      );
    }
    return list;
  }

  List<Widget> _pane(GlimprTokens t) {
    switch (_section) {
      case 1:
        return _screenshotPane(t);
      case 2:
        return _recordingPane(t);
      case 3:
        return _imageEditorPane(t);
      case 4:
        return _selectionHudPane(t);
      case 5:
        return _outputPane(t);
      case 6:
        return _shortcutsPane(t);
      case 7:
        return _advancedPane(t);
      case 8:
        return _aboutPane(t);
      default:
        return _generalPane(t);
    }
  }

  // ---- panes -------------------------------------------------------------

  List<Widget> _aboutPane(GlimprTokens t) {
    return [
      const SizedBox(height: 24),
      Center(
        child: Column(
          children: [
            const GlimprMark(size: 64),
            const SizedBox(height: 14),
            const Wordmark(size: 30),
            const SizedBox(height: 8),
            FutureBuilder<String>(
              future: _appVersionFuture,
              builder: (_, snap) => Text(
                snap.data ?? '',
                style: GlimprType.sansStyle(12.5, 500, t.fg4),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 28),
      GlassCard.rows([
        _aboutLinkRow(t,
            icon: SimpleIcons.kofi,
            label: _l.settingsAboutKofi,
            onTap: () => _openUrl('https://ko-fi.com/howar31')),
        _aboutLinkRow(t,
            icon: SimpleIcons.github,
            label: _l.settingsAboutGithub,
            divider: true,
            onTap: () => _openUrl('https://github.com/howar31/glimpr')),
        _aboutLinkRow(t,
            // Our own site → the Glimpr mark (solid, tinted like the other icons).
            iconWidget: GlimprMark(size: 18, color: t.accentFg),
            label: _l.settingsAboutWebsite,
            divider: true,
            onTap: () => _openUrl('https://glimpr.howar31.com')),
        _aboutLinkRow(t,
            icon: Icons.balance,
            label: _l.settingsAboutLicenses,
            divider: true,
            external: false,
            onTap: _openLicenses),
      ]),
      const SizedBox(height: 22),
      Center(
        child: Text('© 2026 Howar31',
            style: GlimprType.sansStyle(11.5, 500, t.fg4)),
      ),
    ];
  }

  // A full-width tappable About row: SettingRow's icon tile + label, with a
  // trailing affordance (↗ = opens an external URL, › = an in-app page).
  Widget _aboutLinkRow(GlimprTokens t,
      {IconData? icon,
      Widget? iconWidget,
      required String label,
      required VoidCallback onTap,
      bool divider = false,
      bool external = true}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SettingRow(
        icon: icon,
        iconWidget: iconWidget,
        title: label,
        divider: divider,
        trailing: Icon(
          external ? Icons.north_east : Icons.chevron_right,
          size: 18,
          color: t.fg4,
        ),
      ),
    );
  }

  // Open the Glimpr-styled open-source license browser (lib/settings/
  // licenses_page.dart). It reads the SAME auto-generated LicenseRegistry data
  // as Flutter's stock page, just rendered in our own chrome (flat menuBg
  // surface, traffic-light-safe header) — no elevation seams / vibrancy bands.
  void _openLicenses() {
    final ctx = _pageContext;
    if (ctx == null) return;
    final tokens = GlimprTheme.of(ctx);
    Navigator.of(ctx).push(MaterialPageRoute(
      builder: (_) => glimprLicenseSurface(tokens, const LicensesView()),
    ));
  }

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

  /// Screenshot: how a screenshot is taken + what it produces. Format, capture
  /// behaviour, decoration, and the after-screenshot flow.
  List<Widget> _screenshotPane(GlimprTokens t) {
    final lossy = _format == ImageFormat.jpeg;
    return [
      _h1(_l.settingsPaneCapture, t),
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
            SettingCrossFade(
              showFirst: !lossy,
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
      const SizedBox(height: 10),
      // Dual-output HDR screenshots (direct modes only; HEIC on macOS 26+,
      // JPEG XR on Windows). Its own card under the Format section: it is an
      // output-format concern, not capture behaviour.
      GlassCard.rows([
        SettingRow(
          title: _l.settingsHdrScreenshot,
          // Platform-specific wording: each platform names only its own HDR
          // file format (owner feedback 2026-07-03).
          hint: Platform.isWindows
              ? _l.settingsHdrScreenshotHintWindows
              : _l.settingsHdrScreenshotHintMac,
          trailing: GlassToggle(
            value: _hdrScreenshot,
            onChanged: (v) async {
              await _s.setHdrScreenshot(v);
              if (mounted) setState(() => _hdrScreenshot = v);
            },
          ),
        ),
      ]),
      const SizedBox(height: 15),
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
      SectionLabel(_l.settingsSectionDecoration, icon: Icons.filter_frames_outlined),
      GlassCard.rows([
        SettingRow(
          title: _l.settingsDecorationSnap,
          hint: _l.settingsDecorationSnapHint,
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
      SectionLabel(_l.settingsSectionPin, icon: Icons.push_pin_outlined),
      GlassCard.rows([
        SettingRow(
          title: _l.settingsPinHoverGlow,
          hint: _l.settingsPinHoverGlowHint,
          trailing: GlassToggle(
            value: _pinHoverGlow,
            onChanged: (v) async {
              await _s.setPinHoverGlow(v);
              if (mounted) setState(() => _pinHoverGlow = v);
            },
          ),
        ),
      ]),
      const SizedBox(height: 15),
      SectionLabel(_l.settingsSectionAfterCapture, icon: Icons.layers_outlined),
      GlassCard.rows(_flowRows(capture: true)),
      _flowCaption(t, capture: true),
    ];
  }

  /// Selection & HUD: the interactive selection overlay shared by screenshot,
  /// recording live-select, and the editor — loupe, crosshair, marching-ants,
  /// and the right-click-to-exit gesture.
  List<Widget> _selectionHudPane(GlimprTokens t) {
    return [
      _h1(_l.settingsPaneSelectionHud, t),
      // Match the toolbar loupe toggle (Icons.search); distinct from the Magnify
      // TOOL (Icons.zoom_in) so the pixel loupe never reads as the magnifier tool.
      SectionLabel(_l.settingsSectionLoupe, icon: Icons.search),
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
          title: _l.settingsLoupeEnable,
          hint: _l.settingsLoupeEnableHint,
          trailing: GlassToggle(
            value: _hudLoupe,
            onChanged: (v) async {
              await _s.setHudLoupe(v);
              if (mounted) setState(() => _hudLoupe = v);
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
      ]),
    ];
  }

  /// Screen recording (macOS 15+ module): the Format section holds the codec,
  /// resolution, and an AnimatedCrossFade block of format-specific encode
  /// controls (video: quality, fps, system audio, microphone; GIF: fps) that
  /// collapses by format like the screenshot JPEG-quality control, so only that
  /// block changes with the format. Then a stable Behaviour section (cursor,
  /// countdown, stop-after, dim) and the after-recording flow subset.
  List<Widget> _recordingPane(GlimprTokens t) {
    final isGif = _recordFormat == RecordFormat.gif;
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
                (RecordFormat.hevcHdr, 'HEVC (HDR)'),
                (RecordFormat.gif, 'GIF'),
              ],
              onChanged: (v) async {
                await _s.setRecordFormat(v);
                if (mounted) setState(() => _recordFormat = v);
              },
            ),
          ),
          // Format-specific encode controls, collapsed/expanded by format the
          // same way the screenshot JPEG-quality control is (SettingCrossFade,
          // not a disabled placeholder). Only this block changes with format;
          // the format selector above stays anchored. GIF -> firstChild (frame
          // rate only — GIF size is fixed); video -> secondChild (quality,
          // resolution, fps, audio). Resolution + audio are video-only.
          SettingCrossFade(
            showFirst: isGif,
            firstChild: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SettingRow(
                  divider: true,
                  title: _l.settingsRecordingFps,
                  hint: _l.settingsRecordingGifFpsHint,
                  trailing: Segmented<int>(
                    value: _recordGifFps,
                    options: [
                      for (final n in const [10, 15, 20, 25]) (n, '$n fps'),
                    ],
                    onChanged: (v) async {
                      await _s.setRecordGifFps(v);
                      if (mounted) setState(() => _recordGifFps = v);
                    },
                  ),
                ),
              ],
            ),
            secondChild: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Frame rate first, so it sits on the SAME row as the GIF frame
                // rate — that row stays put across a format switch (less jump).
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
                  title: _l.settingsRecordingQuality,
                  hint: _l.settingsRecordingQualityHint,
                  trailing: Segmented<RecordVideoQuality>(
                    value: _recordVideoQuality,
                    options: [
                      (RecordVideoQuality.low, _l.settingsRecordingQualityLow),
                      (RecordVideoQuality.medium,
                          _l.settingsRecordingQualityMedium),
                      (RecordVideoQuality.high, _l.settingsRecordingQualityHigh),
                    ],
                    onChanged: (v) async {
                      await _s.setRecordVideoQuality(v);
                      if (mounted) setState(() => _recordVideoQuality = v);
                    },
                  ),
                ),
                // Output resolution cap (longest side px; native = no cap, far
                // right as the largest). mp4 ONLY — GIF has a fixed size.
                SettingRow(
                  divider: true,
                  title: _l.settingsRecordingResolution,
                  hint: _l.settingsRecordingResolutionHint,
                  trailing: Segmented<int>(
                    value: _recordMaxLongSide,
                    options: [
                      for (final n in const [720, 1280, 1920, 2560]) (n, '$n'),
                      (0, _l.settingsRecordingResolutionNative),
                    ],
                    onChanged: (v) async {
                      await _s.setRecordMaxLongSide(v);
                      if (mounted) setState(() => _recordMaxLongSide = v);
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
                // Windows always mixes both sources into ONE track (a two-track
                // mp4 is unplayable in common Windows players), so this toggle is
                // a no-op there -- hide it. macOS keeps the two-track option.
                if (!Platform.isWindows)
                  SettingRow(
                    divider: true,
                    title: _l.settingsRecordingMergeAudio,
                    hint: _l.settingsRecordingMergeAudioHint,
                    trailing: GlassToggle(
                      value: _recordMergeAudio,
                      onChanged: (v) async {
                        await _s.setRecordMergeAudio(v);
                        if (mounted) setState(() => _recordMergeAudio = v);
                      },
                    ),
                  ),
              ],
            ),
          ),
        ]),
        // GIF buffers every frame in memory until finalize (no incremental
        // flush) — a long GIF can climb into the GBs and run out of memory.
        // Disclose it under the Format card while GIF is the selected format.
        if (isGif) _sectionNote(t, _l.settingsRecordingGifLengthCaution),
        const SizedBox(height: 15),
        SectionLabel(_l.settingsSectionBehaviour,
            icon: Icons.videocam_outlined),
        GlassCard.rows([
          SettingRow(
            title: _l.settingsMousePointer,
            hint: _l.settingsRecordingCursorHint,
            trailing: GlassToggle(
              value: _recordShowCursor,
              onChanged: (v) async {
                await _s.setRecordShowCursor(v);
                if (mounted) setState(() => _recordShowCursor = v);
              },
            ),
          ),
          // Countdown + auto-stop are recording behaviour (when it starts and
          // stops), not output format.
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
          SettingRow(
            divider: true,
            title: _l.settingsRecordingDim,
            hint: _l.settingsRecordingDimHint,
            trailing: GlassToggle(
              value: _recordScrim,
              onChanged: (v) async {
                await _s.setRecordScrim(v);
                if (mounted) setState(() => _recordScrim = v);
              },
            ),
          ),
        ]),
        const SizedBox(height: 15),
        SectionLabel(_l.settingsSectionAfterRecording, icon: Icons.flag_outlined),
        GlassCard.rows([
          SettingRow(
            title: _l.settingsFlowCopyFilePath,
            hint: _l.settingsFlowCopyFilePathHint,
            trailing: _recordingFlowToggle(FlowAction.copyPath),
          ),
          SettingRow(
            divider: true,
            title: Platform.isWindows
                ? _l.settingsFlowShowInFinderWin
                : _l.settingsFlowShowInFinder,
            hint: Platform.isWindows
                ? _l.settingsFlowShowInFinderHintWin
                : _l.settingsFlowShowInFinderHint,
            trailing: _recordingFlowToggle(FlowAction.showInFinder),
          ),
          // Share is macOS-only (no system share surface wired on Windows v1).
          if (!Platform.isWindows)
            SettingRow(
              divider: true,
              title: _l.settingsFlowShareSheet,
              hint: _l.settingsFlowShareSheetHint,
              trailing: _recordingFlowToggle(FlowAction.shareSheet),
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

  /// Image Editor: tool defaults, the recents/gallery history, and the
  /// after-Done flow.
  List<Widget> _imageEditorPane(GlimprTokens t) {
    return [
      _h1(_l.settingsPaneImageEditor, t),
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
      const SizedBox(height: 15),
      SectionLabel(_l.settingsSectionAfterEditorDone,
          icon: Icons.check_circle_outline),
      GlassCard.rows(_flowRows(capture: false)),
      _flowCaption(t, capture: false),
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
                    step: 2, // odd-only: even spans cut half cells at the edges
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
    int step = 1, // snap detent; size uses 2 so the span stays odd
  }) {
    int snap(double v) =>
        (min + ((v - min) / step).round() * step).clamp(min, max);
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
          onChanged: (v) => onChanged(snap(v)),
          onChangeEnd: (v) => onEnd(snap(v)),
        ),
      ],
    );
  }

  List<Widget> _outputPane(GlimprTokens t) {
    return [
      _h1(_l.settingsPaneOutput, t),
      SectionLabel(_l.settingsSectionSaveLocation, icon: Icons.folder_outlined),
      GlassCard.padded(child: _saveFolderBody(t)),
      const SizedBox(height: 15),
      SectionLabel(_l.settingsSectionSubfolder, icon: Icons.account_tree_outlined),
      GlassCard.padded(child: _subfolderBody(t)),
      const SizedBox(height: 15),
      SectionLabel(_l.settingsSectionFilename, icon: Icons.text_fields_outlined),
      GlassCard.padded(child: _filenameBody(t)),
      const SizedBox(height: 15),
      SectionLabel(_l.settingsFilenamePreview, icon: Icons.visibility_outlined),
      GlassCard.padded(child: _previewBody(t)),
    ];
  }

  Widget _patternField(
    GlimprTokens t, {
    required TextEditingController controller,
    required FocusNode focusNode,
    required String hint,
    required ValueChanged<String> onChanged,
    required bool isDefault,
    required VoidCallback onReset,
  }) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            style: GlimprType.mono(13, t.fg1),
            cursorColor: GlimprTokens.accent,
            onChanged: onChanged,
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: t.fieldBg,
              hintText: hint,
              hintStyle: GlimprType.mono(13, t.fg4),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(9),
                borderSide: BorderSide(color: t.fieldBorder),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(9),
                borderSide:
                    const BorderSide(color: GlimprTokens.accent, width: 1.5),
              ),
            ),
          ),
        ),
        const SizedBox(width: 4),
        TokenInsertButton(
          t: t,
          controller: controller,
          focusNode: focusNode,
          onChanged: onChanged,
        ),
        _resetIconButton(t, isDefault: isDefault, onReset: onReset),
      ],
    );
  }

  // The shared Reset-to-default icon button (matches the Shortcuts per-row
  // reset): restart_alt glyph, dimmed + disabled when already at the default.
  Widget _resetIconButton(GlimprTokens t,
          {required bool isDefault, required VoidCallback onReset}) =>
      Opacity(
        opacity: isDefault ? 0.25 : 1,
        child: IconButton(
          tooltip: isDefault ? null : _l.settingsShortcutsResetToDefault,
          icon: Icon(Icons.restart_alt, size: 18, color: t.fg3),
          onPressed: isDefault ? null : onReset,
        ),
      );

  Widget _filenameBody(GlimprTokens t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _patternField(
          t,
          controller: _filenameController,
          focusNode: _filenameFocus,
          hint: defaultFilenameTemplate,
          onChanged: (v) => setState(() => _filenameTemplate = v),
          isDefault: _filenameTemplate == defaultFilenameTemplate,
          onReset: () {
            setState(() {
              _filenameTemplate = defaultFilenameTemplate;
              _filenameWarn = false;
            });
            _filenameController.text = defaultFilenameTemplate;
          },
        ),
        const SizedBox(height: 8),
        Text(_l.settingsFilenameHint,
            style: GlimprType.sansStyle(12, 400, t.fg4)),
        if (_filenameWarn)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(_l.settingsPatternNormalizeHint,
                style: GlimprType.sansStyle(12, 500, GlimprTokens.danger)),
          ),
      ],
    );
  }

  /// The Output Preview: the resolved folder, then the filename under EACH
  /// capture mode — revealing the DISPLAY / LAST / RECORDING labels substituted
  /// for %title/%app when there is no real window, and the date-only collapse on
  /// the bare desktop — plus the _NNN same-name collision rule (via the real
  /// [uniqueName]). A fixed sample time + counter keep the rows stable.
  Widget _previewBody(GlimprTokens t) {
    final ext = _format == ImageFormat.jpeg ? 'jpg' : 'png';
    final fnPattern = _filenameTemplate.trim().isEmpty
        ? defaultFilenameTemplate
        : _filenameTemplate;
    final now = DateTime.now();
    NameContext ctx(String title, String app) => NameContext(
          now: now,
          windowTitle: title,
          appName: app,
          counter: 1,
          rand: (n) => 0,
        );
    String nameFor(String title, String app) =>
        '${renderPattern(fnPattern, ctx(title, app), NameMode.filename)}.$ext';

    // Distinct sample values so %app vs %title are tellable apart in the window
    // row (app = Safari, title = Inbox). The DISPLAY/LAST/RECORDING rows really
    // do set both tokens to the same label — that is faithful, not a sample.
    final sub =
        renderPattern(_subfolderPattern, ctx('Inbox', 'Safari'), NameMode.path)
            .replaceAll('\\', '/');
    final basePath = effectiveSaveDir(resolveSaveDir(_saveDir)).path;
    final segs =
        basePath.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).toList();
    final baseName = segs.isEmpty ? 'Glimpr' : segs.last;
    final folder = '${['…', baseName, if (sub.isNotEmpty) sub].join('/')}/';

    final windowName = nameFor('Inbox', 'Safari');
    final collided = uniqueName(windowName, exists: (n) => n == windowName);

    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 96,
                child:
                    Text(label, style: GlimprType.sansStyle(12, 500, t.fg4)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GlimprType.mono(12, t.fg2)),
              ),
            ],
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(folder, style: GlimprType.mono(12.5, t.fg3)),
        row(_l.settingsPreviewModeWindow, windowName),
        row(_l.settingsPreviewModeDisplay,
            nameFor(kDisplayCaptureLabel, kDisplayCaptureLabel)),
        row(_l.settingsPreviewModeLast,
            nameFor(kLastRegionCaptureLabel, kLastRegionCaptureLabel)),
        row(_l.settingsPreviewModeRecording,
            nameFor(kRecordingCaptureLabel, kRecordingCaptureLabel)),
        row(_l.settingsPreviewModeDesktop, nameFor('', '')),
        row(_l.settingsPreviewCollision, collided),
      ],
    );
  }

  Widget _subfolderBody(GlimprTokens t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _patternField(
          t,
          controller: _subfolderController,
          focusNode: _subfolderFocus,
          hint: defaultSubfolderPattern,
          onChanged: (v) => setState(() => _subfolderPattern = v),
          isDefault: _subfolderPattern == defaultSubfolderPattern,
          onReset: () {
            setState(() {
              _subfolderPattern = defaultSubfolderPattern;
              _subfolderWarn = false;
            });
            _subfolderController.text = defaultSubfolderPattern;
          },
        ),
        const SizedBox(height: 8),
        Text(_l.settingsSubfolderHint,
            style: GlimprType.sansStyle(12, 400, t.fg4)),
        if (_subfolderWarn)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(_l.settingsPatternNormalizeHint,
                style: GlimprType.sansStyle(12, 500, GlimprTokens.danger)),
          ),
      ],
    );
  }

  bool _outputDirty() =>
      _saveDir != _savedSaveDir ||
      _filenameTemplate != _savedFilename ||
      _subfolderPattern != _savedSubfolder;

  // A filename can't span folders: strip ALL filesystem-reserved characters
  // (separators included) so the stored pattern matches the sanitized preview /
  // saved file; trim; empty → default.
  String _normalizeFilename(String s) {
    final v = s.replaceAll(RegExp(r'[/\\:*?"<>|\x00-\x1f]'), '').trim();
    return v.isEmpty ? defaultFilenameTemplate : v;
  }

  // Subfolder: normalize both separators to the portable '/', strip the reserved
  // characters EXCEPT the separator (which is structural), collapse repeats, trim
  // slash/space ends; empty → default (owner: fill the placeholder).
  String _normalizeSubfolder(String s) {
    var v = s.replaceAll('\\', '/');
    v = v.replaceAll(RegExp(r'[:*?"<>|\x00-\x1f]'), '');
    v = v.replaceAll(RegExp(r'/{2,}'), '/');
    v = v.replaceAll(RegExp(r'^[/\s]+|[/\s]+$'), '');
    return v.isEmpty ? defaultSubfolderPattern : v;
  }

  Future<void> _applyOutput() async {
    final fn = _normalizeFilename(_filenameTemplate);
    final sub = _normalizeSubfolder(_subfolderPattern);
    await _s.setFilenameTemplate(fn);
    await _s.setSubfolderPattern(sub);
    if (_saveDir == null) {
      await _s.clearSaveDirectory();
    } else {
      await _s.setSaveDirectory(_saveDir!);
    }
    if (!mounted) return;
    setState(() {
      _filenameTemplate = fn;
      _subfolderPattern = sub;
      _savedFilename = fn;
      _savedSubfolder = sub;
      _savedSaveDir = _saveDir;
      _filenameWarn = false;
      _subfolderWarn = false;
    });
    _filenameController.text = fn;
    _subfolderController.text = sub;
  }

  void _revertOutput() {
    setState(() {
      _saveDir = _savedSaveDir;
      _filenameTemplate = _savedFilename;
      _subfolderPattern = _savedSubfolder;
    });
    _filenameController.text = _savedFilename;
    _subfolderController.text = _savedSubfolder;
  }

  // The Output pane's Apply/Revert bar (pinned at the bottom by _content), shown
  // only when a draft differs from its last-applied baseline. Apply is always
  // valid — it normalizes + fills empty fields on commit.
  Widget _outputFooter(GlimprTokens t) {
    if (!_outputDirty()) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.fromLTRB(28, 12, 28, 16),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: t.divider)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          GhostButton(_l.settingsShortcutsRevert, onTap: _revertOutput),
          const SizedBox(width: 8),
          AccentButton(_l.settingsShortcutsApply, onTap: _applyOutput),
        ],
      ),
    );
  }

  List<Widget> _advancedPane(GlimprTokens t) {
    return [
      _h1(_l.settingsPaneAdvanced, t),
      // Multi-display warm engines: macOS only (the Windows overlay is lazy with
      // no warm pool), so the whole section is hidden on Windows.
      if (!Platform.isWindows) ...[
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
      ],
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
      // Element snap: macOS only (the Windows overlay's elementSnapAt is a
      // deliberate null stub and there is no AX permission to grant), so the
      // whole section is hidden on Windows like the warm-engines one.
      if (!Platform.isWindows) ...[
        SectionLabel(_l.settingsSectionElementSnap, icon: Icons.ads_click),
        GlassCard.padded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _l.settingsElementSnapTitle,
                      style: GlimprType.sansStyle(14.5, 600, t.fg1),
                    ),
                  ),
                  const SizedBox(width: 12),
                  GlassToggle(
                    value: _snapElementMode,
                    onChanged: _setSnapElementMode,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                _l.settingsElementSnapBody,
                style: GlimprType.sansStyle(12.5, 400, t.fg3),
              ),
              if (_snapElementMode && !_axTrusted) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(
                      Icons.lock_outline,
                      size: 15,
                      color: GlimprTokens.danger,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _l.settingsElementSnapNeedsPermission,
                        style:
                            GlimprType.sansStyle(12.5, 600, GlimprTokens.danger),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GhostButton(
                      _l.settingsElementSnapGrant,
                      onTap: () async {
                        await CaptureBridge().requestAccessibility();
                        _recheckAxTrusted();
                      },
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
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
      // Seed from boot-time registration failures so a conflicting binding shows
      // its inline warning + red border + blocks Apply right away (the startup
      // dialog told the user to come check here).
      _baselineInUse = {...?widget.hotkeyService?.failedActions};
      _inUseActions
        ..clear()
        ..addAll(_baselineInUse);
    });
  }

  List<Widget> _shortcutsPane(GlimprTokens t) {
    final draft = _shortcutsDraft;
    if (draft == null) {
      _ensureShortcutsDraft();
      return const [Center(child: CircularProgressIndicator())];
    }
    _scopeChipW = _computeScopeChipWidth();
    final dupes = duplicateActionKeys(draft);

    return [
      _h1(_l.settingsPaneShortcuts, t),
      _shortcutsLegend(t),
      const SizedBox(height: 24),
      SectionLabel(_l.settingsPaneCapture, icon: Icons.crop_free),
      GlassCard.rows([
        for (final a in kGlobalActions)
          // Hide globals that are not available on this platform (Windows:
          // pin / open-editor land in S4, recording in S6).
          if (!kRecordActionKeys.contains(a.actionKey) &&
              isGlobalActionAvailable(a.actionKey))
            SettingRow(
              title: globalActionLabel(_l, a.actionKey),
              hint: globalActionHint(_l, a.actionKey),
              tag: _scopeChip(_l.scopeGlobal),
              warning: _bindingWarning(a.actionKey, dupes),
              trailing: _bindingRow(
                t: t,
                actionKey: a.actionKey,
                dupes: dupes,
              ),
            ),
      ]),
      _sectionNote(t, _l.settingsShortcutsCaptureNote),
      const SizedBox(height: 24),
      // Recording shortcuts (all four modes are wired on macOS + Windows).
      SectionLabel(_l.settingsSectionRecording, icon: Icons.videocam_outlined),
      GlassCard.rows([
        for (final a in kGlobalActions)
          if (kRecordActionKeys.contains(a.actionKey))
            SettingRow(
              title: globalActionLabel(_l, a.actionKey),
              hint: globalActionHint(_l, a.actionKey),
              tag: _scopeChip(_l.scopeGlobal),
              warning: _bindingWarning(a.actionKey, dupes),
              trailing: _bindingRow(
                t: t,
                actionKey: a.actionKey,
                dupes: dupes,
              ),
            ),
      ]),
      _sectionNote(t, _l.settingsShortcutsRecordingNote),
      const SizedBox(height: 24),
      // Tools — tool-selection keys (rebindable), in toolbar order.
      SectionLabel(_l.settingsShortcutsTools, icon: Icons.palette_outlined),
      GlassCard.rows([
        for (final (tool, icon) in kEditorToolMeta)
          SettingRow(
            // Shared with the toolbar tooltips (tool_meta) — never drifts.
            title: toolSettingsLabel(_l, tool),
            icon: icon,
            tag: _scopeChip(_l.scopeEditor),
            // The crop slot's one binding drives crop AND the pin-mode pin
            // selector: crop keeps the standard 18px glyph (row rhythm) and
            // the pin rides its corner as a small badge — the toolbar's
            // shortcut-badge language, crisp-outlined to separate the glyphs.
            iconWidget: tool == ToolKind.crop
                ? _CropPinGlyph(t: t)
                : null,
            warning: _bindingWarning(kEditorToolActionKey[tool]!, dupes),
            trailing: _bindingRow(
              t: t,
              actionKey: kEditorToolActionKey[tool]!,
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
          (
            kEditorToggleCrosshairKey,
            _l.settingsCmdToggleCrosshair,
            _l.settingsCmdToggleCrosshairHint,
          ),
          (
            kEditorToggleLoupeKey,
            _l.settingsCmdToggleLoupe,
            _l.settingsCmdToggleLoupeHint,
          ),
        ])
          SettingRow(
            title: cmd.$2,
            hint: cmd.$3,
            tag: _scopeChip(_l.scopeEditor),
            warning: _bindingWarning(cmd.$1, dupes),
            trailing: _bindingRow(
              t: t,
              actionKey: cmd.$1,
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
          tag: _scopeChip(_l.scopeEditor),
          trailing: _reservedField(t, const [KeyCap('esc')]),
        ),
        SettingRow(
          title: _l.settingsReservedCloseWindow,
          hint: _l.settingsReservedHintEditorSettings,
          tag: _scopeChip(_l.scopeEditor),
          trailing: _reservedField(t, [KeyCap(_cmdCap), const KeyCap('W')]),
        ),
        SettingRow(
          title: _l.settingsReservedOpenSettings,
          hint: _l.settingsReservedHintOverlayEditor,
          tag: _scopeChip(_l.scopeEditor),
          trailing: _reservedField(t, [KeyCap(_cmdCap), const KeyCap(',')]),
        ),
        SettingRow(
          title: _l.settingsReservedNudgeCrosshair,
          hint: _l.settingsReservedHintRegionTools,
          tag: _scopeChip(_l.scopeOverlay),
          trailing: _reservedField(
            t,
            const [KeyCap('←'), KeyCap('↑'), KeyCap('↓'), KeyCap('→')],
          ),
        ),
        // Element-snap walk keys: macOS only, like the Advanced section.
        if (!Platform.isWindows)
          SettingRow(
            title: _l.settingsReservedElementSnapLevel,
            hint: _l.settingsReservedElementSnapLevelHint,
            tag: _scopeChip(_l.scopeOverlay),
            trailing: _reservedField(t, const [KeyCap(','), KeyCap('.')]),
          ),
        SettingRow(
          title: _l.settingsCycleLoupeInfo,
          hint: _l.settingsCycleLoupeInfoHint,
          tag: _scopeChip(_l.scopeOverlay),
          trailing: _reservedField(t, const [KeyCap('?'), KeyCap('/')]),
        ),
        // Image-editor viewport zoom — fixed keys (the capture overlay is 1:1).
        SettingRow(
          title: _l.settingsReservedFitToWindow,
          hint: _l.settingsReservedHintImageEditor,
          tag: _scopeChip(_l.scopeImage),
          trailing: _reservedField(t, [KeyCap(_cmdCap), const KeyCap('1')]),
        ),
        SettingRow(
          title: _l.settingsReservedZoomTo100,
          hint: _l.settingsReservedHintImageEditor,
          tag: _scopeChip(_l.scopeImage),
          trailing: _reservedField(t, [KeyCap(_cmdCap), const KeyCap('2')]),
        ),
        // Text-input semantics, fixed while editing a text annotation — one row
        // per action so the keys don't read as a single chord.
        SettingRow(
          title: _l.settingsReservedCommitText,
          hint: _l.settingsReservedHintWhileEditingText,
          tag: _scopeChip(_l.scopeText),
          trailing: _reservedField(t, const [KeyCap('⏎')]),
        ),
        SettingRow(
          title: _l.settingsReservedNewLine,
          hint: _l.settingsReservedHintWhileEditingText,
          tag: _scopeChip(_l.scopeText),
          trailing: _reservedField(t, const [KeyCap('⇧'), KeyCap('⏎')]),
        ),
        SettingRow(
          title: _l.settingsReservedCancelText,
          hint: _l.settingsReservedHintWhileEditingText,
          tag: _scopeChip(_l.scopeText),
          trailing: _reservedField(t, const [KeyCap('esc')]),
        ),
      ]),
    ];
  }

  // The Shortcuts pane's Apply/Revert bar, pinned to the bottom of the content
  // area (see _content) so it stays reachable however long the list grows. Only
  // shown when the draft is dirty; Apply is disabled (rendered as a dead ghost)
  // when the draft is invalid (a duplicate combo).
  Widget _shortcutsFooter(GlimprTokens t) {
    final draft = _shortcutsDraft;
    if (draft == null || _mapEquals(draft, _shortcutsBaseline)) {
      return const SizedBox.shrink();
    }
    final allValid = _allValid(duplicateActionKeys(draft));
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

  // The row's danger sub-line, shown under the title (NOT inline in the recorder
  // row) so the trailing stays narrow and the leading scope tag never overflows.
  // Two cases: a duplicate combo, or a combo the OS refused to register (reserved
  // / already taken by another app) — the latter mirrors ShareX's inline failed
  // status instead of a dialog. Bare keys are allowed (no missing-modifier case).
  String? _bindingWarning(String actionKey, Set<String> dupes) {
    if (dupes.contains(actionKey)) return _l.settingsShortcutsDuplicate;
    if (_inUseActions.contains(actionKey)) return _l.settingsShortcutsInUse;
    return null;
  }

  Widget _bindingRow({
    required GlimprTokens t,
    required String actionKey,
    required Set<String> dupes,
  }) {
    final draft = _shortcutsDraft!;
    final binding = draft[actionKey];
    final isDefault = binding == defaultBindingFor(actionKey);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        HotkeyRecorderField(
          value: binding,
          // Red border when this row's combo is invalid (duplicate / in use).
          hasWarning: _bindingWarning(actionKey, dupes) != null,
          // Every row rejects the same fixed editor/system combos (⌘W, ⌘1, ⌘2,
          // bare , / . , / and the ⌘, settings chord), so a binding can never
          // land on a reserved shortcut anywhere on the page.
          isReserved: isEditorReservedCombo,
          onChanged: (b, {bool available = true}) => setState(() {
            draft[actionKey] = b;
            if (b != null && !available) {
              _inUseActions.add(actionKey); // taken by the OS / another app
            } else {
              _inUseActions.remove(actionKey);
            }
          }),
          onRecordingChanged: _onRecordingChanged,
          // Windows: the registrar also captures keys natively (Flutter drops
          // PrintScreen + the Win key). macOS registrar isn't a HotkeyKeyCapture
          // -> null -> the field reads Flutter key events.
          keyCapture: switch (widget.hotkeyService?.registrar) {
            final HotkeyKeyCapture c => c,
            _ => null,
          },
        ),
        const SizedBox(width: 4),
        // Reset to default — disabled + dimmed when the binding already is the
        // default (nothing to reset), so it reads as inactive.
        _resetIconButton(
          t,
          isDefault: isDefault,
          onReset: () => setState(() {
            final d = defaultBindingFor(actionKey);
            draft[actionKey] = d;
            // Reset-to-default normally clears the in-use flag; keep it only if
            // the default IS the still-conflicting baseline binding.
            if (_baselineInUse.contains(actionKey) &&
                d == _shortcutsBaseline[actionKey]) {
              _inUseActions.add(actionKey);
            } else {
              _inUseActions.remove(actionKey);
            }
          }),
        ),
      ],
    );
  }

  // Valid when there are no duplicate combos AND nothing is reserved/taken by the
  // OS / another app. Bare keys are allowed (a bare PrintScreen / F-key is a
  // legitimate global hotkey, ShareX-style).
  bool _allValid(Set<String> dupes) => dupes.isEmpty && _inUseActions.isEmpty;

  Future<void> _applyShortcuts() async {
    final draft = _shortcutsDraft!;
    await _shortcutStore.saveAll(draft);
    // Re-register the changed Tier-1 actions live (no restart). Apply is only
    // reachable when every binding is valid (no duplicate, nothing in use — the
    // record-time probe blocked those), so these registrations succeed.
    for (final a in kGlobalActions) {
      if (draft[a.actionKey] != _shortcutsBaseline[a.actionKey]) {
        await widget.hotkeyService?.rebind(a.actionKey, draft[a.actionKey]);
      }
    }
    // Apply is only reachable when _inUseActions is empty, so the new baseline is
    // conflict-free — clear the baseline-conflict snapshot too.
    if (mounted) {
      setState(() {
        _shortcutsBaseline = {...draft};
        _baselineInUse = {};
      });
    }
  }

  void _revertShortcuts() => setState(() {
        _shortcutsDraft = {..._shortcutsBaseline};
        // Restore the baseline's conflicts (boot failures) — don't wipe a
        // still-valid error.
        _inUseActions
          ..clear()
          ..addAll(_baselineInUse);
      });

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

  // The command-modifier cap for reserved rows: the real chords are Ctrl-based
  // on Windows (Ctrl+W close, Ctrl+, settings, Ctrl+1/2 zoom), ⌘ on macOS.
  String get _cmdCap => Platform.isWindows ? 'Ctrl' : '⌘';

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
            const SizedBox(width: 4),
            _resetIconButton(t, isDefault: path == null, onReset: _resetDir),
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
