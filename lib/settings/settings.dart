import 'dart:io';
import '../capture/capture_kind.dart';
import '../editor/hud_config.dart';
import '../editor/loupe_config.dart';
import '../output/filename.dart';
import '../output/flow.dart';
import '../shortcuts/hotkey_binding.dart';
import '../shortcuts/shortcut_store.dart';
import 'settings_store.dart';

/// Output image format for a saved / copied capture.
enum ImageFormat { png, jpeg }

/// Immutable snapshot of every capture-time setting, read once per capture (off
/// the hot path) so the shutter sound and delivery never await the store. The
/// defaults reproduce the original behaviour (PNG, all sounds + legs on).
class CaptureSettings {
  const CaptureSettings({
    this.saveDir,
    this.format = ImageFormat.png,
    this.jpegQuality = 90,
    this.shutterSound = true,
    this.completionSound = true,
    this.flow = const {FlowAction.copy, FlowAction.save},
    this.rightClickExits = true,
    this.filenameTemplate = defaultFilenameTemplate,
    this.subfolderPattern = defaultSubfolderPattern,
    this.decorateSnap = false,
    this.decorateCrop = false,
    this.decorateWindow = false,
    this.decorateDisplay = false,
    this.decorateLastRegion = false,
    this.decorationJpegFill = 0xFFFFFFFF,
    this.captureCursor = false,
    this.snapElementMode = false,
    this.hdrScreenshot = false,
  });

  final Directory? saveDir;
  final ImageFormat format;
  final int jpegQuality; // 1-100; used only when format is jpeg
  final bool shutterSound;
  final bool completionSound;
  // The after-capture completion flow (multi-select; see FlowAction). Replaces
  // the old saveToFile/copyToClipboard pair — those are now flow members.
  final Set<FlowAction> flow;
  final bool rightClickExits; // right-click on empty space leaves capture mode
  final String filenameTemplate; // %-tokens, see kNameTokens
  final String subfolderPattern; // output subfolder %-pattern (path mode)

  // Opt-in capture decoration (margin + rounded corners + drop shadow), gated
  // per capture scenario. All off by default => output is byte-identical.
  final bool decorateSnap; // overlay snap-to-window
  final bool decorateCrop; // overlay freehand crop rect
  final bool decorateWindow; // direct focused-window capture
  final bool decorateDisplay; // direct display capture
  final bool decorateLastRegion; // direct last-region capture
  final int decorationJpegFill; // ARGB; the JPEG margin fill colour
  final bool captureCursor; // include the mouse pointer in the capture
  // Precise AX element snap (Advanced experiment): the overlay snaps to the
  // Accessibility element under the cursor instead of the whole window. Default
  // off; needs the macOS Accessibility permission, falls back to window snap.
  final bool snapElementMode;
  // Dual-output HDR screenshots (direct modes only): on an HDR display the
  // window/display/last-region captures also save an HDR file (HEIC on macOS 26+,
  // JPEG XR on Windows) beside the standard image. Default off.
  final bool hdrScreenshot;

  static const defaults = CaptureSettings();

  bool get isJpeg => format == ImageFormat.jpeg;
  String get fileExtension => isJpeg ? 'jpg' : 'png';

  /// Whether [kind]'s scenario has decoration enabled. The whole-display overlay
  /// export and any non-listed kind are never decorated.
  bool decorateFor(CaptureKind kind) => switch (kind) {
    CaptureKind.overlaySnap => decorateSnap,
    CaptureKind.overlayCrop => decorateCrop,
    CaptureKind.focusedWindow => decorateWindow,
    CaptureKind.display => decorateDisplay,
    CaptureKind.lastRegion => decorateLastRegion,
    CaptureKind.overlayWholeDisplay => false,
  };
}

/// The settings that are SAFE to hot-reload mid-session on ANY surface (capture
/// overlay / image editor): pure "config", NEVER in-session interaction state
/// (tool styles, current tool/selection, the per-shot cursor toggle, per-take
/// record overrides — those must NOT be clobbered on a Settings-close, so they
/// are deliberately ABSENT here). Both surfaces re-read this whole bundle via
/// [Settings.loadAppConfig] on every Settings-close (overlay `onResume`, editor
/// `settingsClosed` / `windowBecameKey`). To make a NEW config setting
/// hot-reload everywhere, add it to an EXISTING member struct below (LoupeConfig
/// / HudConfig / CaptureSettings) — it then flows through BOTH session-start and
/// reload for free, no per-surface patch. A brand-new category is the only case
/// that also needs a new field here.
class AppConfig {
  const AppConfig({
    required this.loupe,
    required this.hud,
    required this.capture,
    required this.bindings,
  });
  final LoupeConfig loupe;
  final HudConfig hud;
  final CaptureSettings capture;
  final Map<String, HotkeyBinding?> bindings; // editor + reserved hotkeys
}

/// Typed access to persisted settings, shared by the settings UI (writes) and
/// the overlay engines (reads). All engines hit the same NSUserDefaults.
class Settings {
  Settings(this.store);
  final SettingsStore store;

  /// Process-wide instance backed by the platform store (one per engine).
  static final Settings instance = Settings(PrefsSettingsStore());

  static const _saveDirKey = 'save_directory';
  static const _formatKey = 'image_format';
  static const _jpegQualityKey = 'jpeg_quality';
  static const _shutterSoundKey = 'shutter_sound';
  static const _completionSoundKey = 'completion_sound';
  static const _flowAfterCaptureKey = 'flow_after_capture';
  static const _flowAfterEditorDoneKey = 'flow_after_editor_done';
  static const _rightClickExitsKey = 'right_click_exits';
  static const _confirmOnExitKey = 'confirm_on_exit';
  static const _filenameTemplateKey = 'filename_template';
  static const _subfolderPatternKey = 'subfolder_pattern';
  static const _nameCounterKey = 'name_counter';
  static const _decorateSnapKey = 'decorate_snap';
  static const _decorateCropKey = 'decorate_crop';
  static const _decorateWindowKey = 'decorate_window';
  static const _decorateDisplayKey = 'decorate_display';
  static const _decorateLastRegionKey = 'decorate_last_region';
  static const _decorationJpegFillKey = 'decoration_jpeg_fill';
  static const _captureCursorKey = 'capture_cursor';
  static const _snapElementModeKey = 'snap_element_mode';
  static const _hdrScreenshotKey = 'hdr_screenshot';
  static const _pinHoverGlowKey = 'pin_hover_glow';
  static const _recordFormatKey = 'record_format';
  static const _recordFpsKey = 'record_fps';
  static const _recordCursorKey = 'record_show_cursor';
  static const _recordScrimKey = 'record_scrim';
  static const _recordSystemAudioKey = 'record_system_audio';
  static const _recordMicKey = 'record_microphone';
  static const _recordMergeAudioKey = 'record_merge_audio';
  static const _flowAfterRecordingKey = 'flow_after_recording';
  static const _recordMaxDurationKey = 'record_max_duration';
  static const _recordCountdownKey = 'record_countdown';
  static const _recordVideoQualityKey = 'record_video_quality';
  static const _recordMaxLongSideKey = 'record_max_long_side';
  static const _recordGifFpsKey = 'record_gif_fps';
  static const _loupeSpanKey = 'loupe_span';
  static const _loupeZoomKey = 'loupe_zoom';
  static const _loupeInfoModeKey = 'loupe_info_mode';
  static const _eyedropperToolKeysKey = 'eyedropper_tool_keys_cancel';
  static const _hudCrosshairKey = 'hud_crosshair';
  static const _hudLoupeKey = 'hud_loupe';
  static const _hudMarchingAntsKey = 'hud_marching_ants';
  static const _captureLayerCapKey = 'capture_layer_cap';
  static const _appLanguageKey = 'app_language';

  // Save folder ------------------------------------------------------------
  Future<String?> getSaveDirectory() => store.getString(_saveDirKey);
  Future<void> setSaveDirectory(String path) =>
      store.setString(_saveDirKey, path);
  Future<void> clearSaveDirectory() => store.remove(_saveDirKey);

  // Output format + JPEG quality ------------------------------------------
  Future<ImageFormat> getFormat() async =>
      (await store.getString(_formatKey)) == 'jpeg'
      ? ImageFormat.jpeg
      : ImageFormat.png;
  Future<void> setFormat(ImageFormat f) =>
      store.setString(_formatKey, f == ImageFormat.jpeg ? 'jpeg' : 'png');

  Future<int> getJpegQuality() async =>
      (await store.getInt(_jpegQualityKey)) ?? 90;
  Future<void> setJpegQuality(int q) =>
      store.setInt(_jpegQualityKey, q.clamp(1, 100));

  // Sounds -----------------------------------------------------------------
  Future<bool> getShutterSound() async =>
      (await store.getBool(_shutterSoundKey)) ?? true;
  Future<void> setShutterSound(bool v) => store.setBool(_shutterSoundKey, v);

  Future<bool> getCompletionSound() async =>
      (await store.getBool(_completionSoundKey)) ?? true;
  Future<void> setCompletionSound(bool v) =>
      store.setBool(_completionSoundKey, v);

  // Completion flows ---------------------------------------------------------

  /// The after-capture flow. Defaults to copy+save when never configured.
  Future<Set<FlowAction>> getAfterCaptureFlow() async {
    final stored = await store.getString(_flowAfterCaptureKey);
    if (stored != null) return parseFlow(stored);
    return {FlowAction.copy, FlowAction.save};
  }

  Future<void> setAfterCaptureFlow(Set<FlowAction> s) =>
      store.setString(_flowAfterCaptureKey, flowToString(s));

  /// The after-editor-Done flow (openEditor never applies here).
  Future<Set<FlowAction>> getAfterEditorDoneFlow() async {
    final stored = await store.getString(_flowAfterEditorDoneKey);
    if (stored != null) return parseFlow(stored);
    return {FlowAction.copy, FlowAction.save};
  }

  Future<void> setAfterEditorDoneFlow(Set<FlowAction> s) =>
      store.setString(_flowAfterEditorDoneKey, flowToString(s));

  // Capture interaction --------------------------------------------------
  Future<bool> getRightClickExits() async =>
      (await store.getBool(_rightClickExitsKey)) ?? true;
  Future<void> setRightClickExits(bool v) =>
      store.setBool(_rightClickExitsKey, v);

  /// Confirm before exiting a capture that still has unsaved annotations
  /// (right-click on empty space or Esc). Default ON to protect annotations.
  Future<bool> getConfirmOnExit() async =>
      (await store.getBool(_confirmOnExitKey)) ?? true;
  Future<void> setConfirmOnExit(bool v) =>
      store.setBool(_confirmOnExitKey, v);

  // Filename template ------------------------------------------------------
  Future<String> getFilenameTemplate() async {
    final s = await store.getString(_filenameTemplateKey);
    return (s == null || s.trim().isEmpty) ? defaultFilenameTemplate : s;
  }

  Future<void> setFilenameTemplate(String v) =>
      store.setString(_filenameTemplateKey, v);

  // Output subfolder pattern. Unlike the filename, an EMPTY value is valid
  // (= no subfolder); only an unset key falls back to the date default.
  Future<String> getSubfolderPattern() async =>
      (await store.getString(_subfolderPatternKey)) ?? defaultSubfolderPattern;

  Future<void> setSubfolderPattern(String v) =>
      store.setString(_subfolderPatternKey, v);

  // Persistent `%i` auto-increment counter (global, ShareX-style). Advanced by
  // the capture path only when a rendered pattern actually uses `%i`.
  Future<int> getNameCounter() async =>
      (await store.getInt(_nameCounterKey)) ?? 0;

  Future<void> setNameCounter(int v) => store.setInt(_nameCounterKey, v);

  // Capture decoration (opt-in, per scenario) ----------------------------
  Future<bool> getDecorateSnap() async =>
      (await store.getBool(_decorateSnapKey)) ?? false;
  Future<void> setDecorateSnap(bool v) => store.setBool(_decorateSnapKey, v);

  Future<bool> getDecorateCrop() async =>
      (await store.getBool(_decorateCropKey)) ?? false;
  Future<void> setDecorateCrop(bool v) => store.setBool(_decorateCropKey, v);

  Future<bool> getDecorateWindow() async =>
      (await store.getBool(_decorateWindowKey)) ?? true;
  Future<void> setDecorateWindow(bool v) =>
      store.setBool(_decorateWindowKey, v);

  Future<bool> getDecorateDisplay() async =>
      (await store.getBool(_decorateDisplayKey)) ?? false;
  Future<void> setDecorateDisplay(bool v) =>
      store.setBool(_decorateDisplayKey, v);

  Future<bool> getDecorateLastRegion() async =>
      (await store.getBool(_decorateLastRegionKey)) ?? false;
  Future<void> setDecorateLastRegion(bool v) =>
      store.setBool(_decorateLastRegionKey, v);

  Future<int> getDecorationJpegFill() async =>
      (await store.getInt(_decorationJpegFillKey)) ?? 0xFF202327;
  Future<void> setDecorationJpegFill(int argb) =>
      store.setInt(_decorationJpegFillKey, argb);

  // Capture mouse pointer ---------------------------------------------------
  Future<bool> getCaptureCursor() async =>
      (await store.getBool(_captureCursorKey)) ?? true;
  Future<void> setCaptureCursor(bool v) =>
      store.setBool(_captureCursorKey, v);

  // Precise AX element snap (Advanced experiment). Default OFF.
  Future<bool> getSnapElementMode() async =>
      (await store.getBool(_snapElementModeKey)) ?? false;
  Future<void> setSnapElementMode(bool v) =>
      store.setBool(_snapElementModeKey, v);

  // Dual-output HDR screenshots for the direct capture modes. Default OFF.
  Future<bool> getHdrScreenshot() async =>
      (await store.getBool(_hdrScreenshotKey)) ?? false;
  Future<void> setHdrScreenshot(bool v) =>
      store.setBool(_hdrScreenshotKey, v);

  // Pinned-window hover glow (Aurora corona). Default ON; read live by the
  // native PinPanel on each hover.
  Future<bool> getPinHoverGlow() async =>
      (await store.getBool(_pinHoverGlowKey)) ?? true;
  Future<void> setPinHoverGlow(bool v) =>
      store.setBool(_pinHoverGlowKey, v);

  // Screen recording (macOS 15+ module) -------------------------------------
  /// The recording output format (SSOT). [RecordFormat.gif] selects the direct
  /// ImageIO GIF path (no mp4, no audio); h264/hevc are the mp4 codecs.
  Future<RecordFormat> getRecordFormat() async {
    switch (await store.getString(_recordFormatKey)) {
      case 'gif':
        return RecordFormat.gif;
      case 'hevcHdr':
        return RecordFormat.hevcHdr;
      case 'hevc':
        return RecordFormat.hevc;
      case 'h264':
        return RecordFormat.h264;
    }
    return RecordFormat.gif; // default format
  }

  Future<void> setRecordFormat(RecordFormat f) =>
      store.setString(_recordFormatKey, f.name);

  Future<int> getRecordFps() async {
    final v = (await store.getInt(_recordFpsKey)) ?? 60;
    return v == 60 ? 60 : 30;
  }

  Future<void> setRecordFps(int v) =>
      store.setInt(_recordFpsKey, v == 60 ? 60 : 30);

  Future<bool> getRecordShowCursor() async =>
      (await store.getBool(_recordCursorKey)) ?? true;
  Future<void> setRecordShowCursor(bool v) =>
      store.setBool(_recordCursorKey, v);

  /// Whether to dim the area outside the recorded region + dim other displays
  /// (the recording scrims). Default on; users turn it off for a clear screen
  /// during long recordings. The red region frame/brackets are unaffected.
  Future<bool> getRecordScrim() async =>
      (await store.getBool(_recordScrimKey)) ?? true;
  Future<void> setRecordScrim(bool v) => store.setBool(_recordScrimKey, v);

  Future<bool> getRecordSystemAudio() async =>
      (await store.getBool(_recordSystemAudioKey)) ?? true;
  Future<void> setRecordSystemAudio(bool v) =>
      store.setBool(_recordSystemAudioKey, v);

  Future<bool> getRecordMicrophone() async =>
      (await store.getBool(_recordMicKey)) ?? true;
  Future<void> setRecordMicrophone(bool v) =>
      store.setBool(_recordMicKey, v);

  /// Merge system audio + mic into ONE mp4 audio track (default off = two
  /// separate tracks). Only takes effect when BOTH sources are recorded.
  Future<bool> getRecordMergeAudio() async =>
      (await store.getBool(_recordMergeAudioKey)) ?? false;
  Future<void> setRecordMergeAudio(bool v) =>
      store.setBool(_recordMergeAudioKey, v);

  /// Fixed recording duration in seconds; 0 = off. Off-step values clamp to 0.
  static const kRecordMaxDurations = <int>[0, 5, 10, 15, 30, 60];
  Future<int> getRecordMaxDuration() async {
    final v = (await store.getInt(_recordMaxDurationKey)) ?? 0;
    return kRecordMaxDurations.contains(v) ? v : 0;
  }

  Future<void> setRecordMaxDuration(int v) => store.setInt(
      _recordMaxDurationKey, kRecordMaxDurations.contains(v) ? v : 0);

  /// Countdown start delay in seconds; 0 = off. Off-step values clamp to 0.
  static const kRecordCountdowns = <int>[0, 3, 5, 10];
  Future<int> getRecordCountdown() async {
    final v = (await store.getInt(_recordCountdownKey)) ?? 0;
    return kRecordCountdowns.contains(v) ? v : 0;
  }

  Future<void> setRecordCountdown(int v) => store.setInt(
      _recordCountdownKey, kRecordCountdowns.contains(v) ? v : 0);

  /// mp4 video quality tier (SSOT). The user picks a self-labeling tier; the
  /// native encoder maps it to an average bitrate (bits-per-pixel × final
  /// resolution × fps), so the same tier yields consistent quality at any
  /// resolution. Does not apply to GIF (256-color ImageIO).
  Future<RecordVideoQuality> getRecordVideoQuality() async {
    switch (await store.getString(_recordVideoQualityKey)) {
      case 'low':
        return RecordVideoQuality.low;
      case 'medium':
        return RecordVideoQuality.medium;
      case 'high':
        return RecordVideoQuality.high;
    }
    return RecordVideoQuality.high; // default
  }

  Future<void> setRecordVideoQuality(RecordVideoQuality q) =>
      store.setString(_recordVideoQualityKey, q.name);

  /// Output resolution cap: the longest side in pixels; 0 = native (no cap).
  /// Shared by mp4 and GIF. Off-step values clamp to the 0 (native) default.
  static const kRecordMaxLongSides = <int>[0, 720, 1280, 1920, 2560];
  Future<int> getRecordMaxLongSide() async {
    final v = (await store.getInt(_recordMaxLongSideKey)) ?? 0;
    return kRecordMaxLongSides.contains(v) ? v : 0;
  }

  Future<void> setRecordMaxLongSide(int v) => store.setInt(
      _recordMaxLongSideKey, kRecordMaxLongSides.contains(v) ? v : 0);

  /// GIF frame rate in frames per second. Off-step values clamp to 15.
  static const kRecordGifFps = <int>[10, 15, 20, 25];
  Future<int> getRecordGifFps() async {
    final v = (await store.getInt(_recordGifFpsKey)) ?? 15;
    return kRecordGifFps.contains(v) ? v : 15;
  }

  Future<void> setRecordGifFps(int v) =>
      store.setInt(_recordGifFpsKey, kRecordGifFps.contains(v) ? v : 15);

  /// The after-recording flow: the path-based subset only (copyPath /
  /// showInFinder / shareSheet). Default = none (silent save, owner decision).
  Future<Set<FlowAction>> getAfterRecordingFlow() async {
    final stored = await store.getString(_flowAfterRecordingKey);
    return stored == null
        ? const <FlowAction>{}
        : parseFlow(stored).intersection(kRecordingFlowActions);
  }

  Future<void> setAfterRecordingFlow(Set<FlowAction> s) => store.setString(
      _flowAfterRecordingKey,
      flowToString(s.intersection(kRecordingFlowActions)));

  /// One bundle for the recording controller (mirrors [loadCapture]'s shape).
  Future<RecordingSettings> loadRecording() async => RecordingSettings(
        format: await getRecordFormat(),
        fps: await getRecordFps(),
        showCursor: await getRecordShowCursor(),
        scrim: await getRecordScrim(),
        systemAudio: await getRecordSystemAudio(),
        microphone: await getRecordMicrophone(),
        mergeAudio: await getRecordMergeAudio(),
        maxDuration: await getRecordMaxDuration(),
        countdown: await getRecordCountdown(),
        videoQuality: await getRecordVideoQuality(),
        maxLongSide: await getRecordMaxLongSide(),
        gifFps: await getRecordGifFps(),
        flow: await getAfterRecordingFlow(),
      );

  // Loupe geometry (shared by overlay + image editor) ----------------------
  // Getters clamp on read too, so a corrupt / out-of-range stored value stays
  // safe.
  // App language --------------------------------------------------------------
  // 'system' (default) | 'en' | 'zh' (Traditional Chinese). Applies on
  // restart; the native side reads the same NSUserDefaults key
  // ("app_language", no prefix: SharedPreferencesAsync) at launch for its
  // menu/alert strings.
  Future<String> getAppLanguage() async {
    final v = await store.getString(_appLanguageKey);
    return (v == 'en' || v == 'zh') ? v! : 'system';
  }

  Future<void> setAppLanguage(String v) =>
      store.setString(_appLanguageKey, (v == 'en' || v == 'zh') ? v : 'system');

  // Capture layer stack ------------------------------------------------------
  // How many freeze layers one overlay session may hold (1-5, default 3).
  // 1 = no stacking: a capture hotkey during a live session replaces it.
  Future<int> getCaptureLayerCap() async =>
      ((await store.getInt(_captureLayerCapKey)) ?? 3).clamp(1, 5);
  Future<void> setCaptureLayerCap(int v) =>
      store.setInt(_captureLayerCapKey, v.clamp(1, 5));

  Future<int> getLoupeSpan() async =>
      clampLoupeSpan((await store.getInt(_loupeSpanKey)) ?? kLoupeSpanDefault);
  Future<void> setLoupeSpan(int v) =>
      store.setInt(_loupeSpanKey, clampLoupeSpan(v));

  Future<int> getLoupeZoom() async =>
      ((await store.getInt(_loupeZoomKey)) ?? kLoupeZoomDefault)
          .clamp(kLoupeZoomMin, kLoupeZoomMax);
  Future<void> setLoupeZoom(int v) =>
      store.setInt(_loupeZoomKey, v.clamp(kLoupeZoomMin, kLoupeZoomMax));

  // Loupe info display (`?`/`/` cycle): persisted so the choice survives
  // relaunch. Stored as the enum name; an unknown/missing value reads as
  // shortcuts (the default).
  Future<LoupeInfoMode> getLoupeInfoMode() async {
    final name = await store.getString(_loupeInfoModeKey);
    return LoupeInfoMode.values.firstWhere(
      (m) => m.name == name,
      orElse: () => LoupeInfoMode.shortcuts,
    );
  }

  Future<void> setLoupeInfoMode(LoupeInfoMode v) =>
      store.setString(_loupeInfoModeKey, v.name);

  // Eyedropper: what a tool shortcut does while sampling (true = cancel
  // sampling and switch — the default; false = sampling is modal).
  Future<bool> getEyedropperToolKeysCancel() async =>
      (await store.getBool(_eyedropperToolKeysKey)) ?? true;
  Future<void> setEyedropperToolKeysCancel(bool v) =>
      store.setBool(_eyedropperToolKeysKey, v);

  /// One-shot loupe geometry snapshot, read by the overlay (per capture) and the
  /// image editor (per open).
  Future<LoupeConfig> loadLoupe() async => LoupeConfig(
        span: await getLoupeSpan(),
        zoom: await getLoupeZoom(),
        toolKeysCancelSampling: await getEyedropperToolKeysCancel(),
        infoMode: await getLoupeInfoMode(),
      );

  // HUD options (crosshair lines + marching-ants animation) ----------------
  Future<bool> getHudCrosshair() async =>
      (await store.getBool(_hudCrosshairKey)) ?? true;
  Future<void> setHudCrosshair(bool v) => store.setBool(_hudCrosshairKey, v);

  Future<bool> getHudLoupe() async =>
      (await store.getBool(_hudLoupeKey)) ?? true;
  Future<void> setHudLoupe(bool v) => store.setBool(_hudLoupeKey, v);

  Future<bool> getHudMarchingAnts() async =>
      (await store.getBool(_hudMarchingAntsKey)) ?? true;
  Future<void> setHudMarchingAnts(bool v) =>
      store.setBool(_hudMarchingAntsKey, v);

  /// One-shot HUD options snapshot, read by the overlay (per capture) and the
  /// image editor (per open); hot-reloaded alongside the loupe.
  Future<HudConfig> loadHud() async => HudConfig(
    crosshair: await getHudCrosshair(),
    loupe: await getHudLoupe(),
    marchingAnts: await getHudMarchingAnts(),
  );

  /// One-shot snapshot of every capture-time setting (prefetched per capture).
  Future<CaptureSettings> loadCapture() async => CaptureSettings(
    saveDir: resolveSaveDir(await getSaveDirectory()),
    format: await getFormat(),
    jpegQuality: await getJpegQuality(),
    shutterSound: await getShutterSound(),
    completionSound: await getCompletionSound(),
    flow: await getAfterCaptureFlow(),
    rightClickExits: await getRightClickExits(),
    filenameTemplate: await getFilenameTemplate(),
    subfolderPattern: await getSubfolderPattern(),
    decorateSnap: await getDecorateSnap(),
    decorateCrop: await getDecorateCrop(),
    decorateWindow: await getDecorateWindow(),
    decorateDisplay: await getDecorateDisplay(),
    decorateLastRegion: await getDecorateLastRegion(),
    decorationJpegFill: await getDecorationJpegFill(),
    captureCursor: await getCaptureCursor(),
    snapElementMode: await getSnapElementMode(),
    hdrScreenshot: await getHdrScreenshot(),
  );

  /// One-shot snapshot of every HOT-RELOADABLE config setting (see [AppConfig]).
  /// The single source of truth for "what re-reads on a Settings-close" — both
  /// the capture overlay and the image editor call this in their reload. Loads
  /// all members in parallel.
  Future<AppConfig> loadAppConfig() async {
    final loupe = loadLoupe();
    final hud = loadHud();
    final capture = loadCapture();
    final bindings = ShortcutStore(store).all();
    return AppConfig(
      loupe: await loupe,
      hud: await hud,
      capture: await capture,
      bindings: await bindings,
    );
  }
}

/// Maps a stored save-folder path to a Directory, or null when unset/empty so
/// the delivery path falls back to its built-in default.
Directory? resolveSaveDir(String? path) =>
    (path != null && path.isNotEmpty) ? Directory(path) : null;

/// Screen-recording settings bundle (macOS 15+ module). Loaded once per
/// recording start by the record controller; the save folder and filename
/// template come from [CaptureSettings] (shared output conventions).
/// The recording output format. h264/hevc are mp4 codecs; hevcHdr is HEVC with
/// HDR10 output when the recorded display is HDR (silently records plain SDR
/// HEVC otherwise); gif is the direct ImageIO animated-GIF path (no mp4, no
/// audio).
enum RecordFormat { h264, hevc, hevcHdr, gif }

/// mp4 video quality tier. Maps natively to an average encoder bitrate; GIF
/// ignores it (256-color ImageIO).
enum RecordVideoQuality { low, medium, high }

class RecordingSettings {
  const RecordingSettings({
    this.format = RecordFormat.gif,
    this.fps = 60,
    this.showCursor = true,
    this.scrim = true,
    this.systemAudio = true,
    this.microphone = true,
    this.mergeAudio = false,
    this.maxDuration = 0,
    this.countdown = 0,
    this.videoQuality = RecordVideoQuality.high,
    this.maxLongSide = 0,
    this.gifFps = 15,
    this.flow = const {},
  });

  final RecordFormat format;
  // hevcHdr rides the HEVC codec path (Main10 when the display is HDR).
  bool get hevc =>
      format == RecordFormat.hevc || format == RecordFormat.hevcHdr;
  bool get hdr => format == RecordFormat.hevcHdr;
  bool get isGif => format == RecordFormat.gif;
  final int fps; // 30 | 60
  final bool showCursor;
  final bool scrim; // dim outside the region + other displays
  final bool systemAudio;
  final bool microphone;
  final bool mergeAudio; // merge both audio sources into one track (both-on only)
  final int maxDuration; // seconds; 0 = off (auto-stop disabled)
  final int countdown; // seconds; 0 = off (start delay)
  final RecordVideoQuality videoQuality; // mp4 only
  final int maxLongSide; // longest side px cap; 0 = native (shared mp4/GIF)
  final int gifFps; // 10 | 15 | 20 | 25
  final Set<FlowAction> flow; // after-recording, kRecordingFlowActions subset
}
