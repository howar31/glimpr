// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get settingsLanguage => 'Language';

  @override
  String get settingsPaneGeneral => 'General';

  @override
  String get settingsPaneCapture => 'Screenshot';

  @override
  String get settingsPaneRecording => 'Recording';

  @override
  String get settingsPaneOutput => 'Output';

  @override
  String get settingsPaneShortcuts => 'Shortcuts';

  @override
  String get settingsPaneAdvanced => 'Advanced';

  @override
  String get settingsPaneAbout => 'About';

  @override
  String get settingsAboutKofi => 'Support';

  @override
  String get settingsAboutGithub => 'Source code';

  @override
  String get settingsAboutWebsite => 'Website';

  @override
  String get settingsAboutLicenses => 'Licenses & acknowledgements';

  @override
  String settingsLicenseCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count licenses',
      one: '1 license',
    );
    return '$_temp0';
  }

  @override
  String get settingsPaneImageEditor => 'Image Editor';

  @override
  String get settingsPaneSelectionHud => 'Selection & HUD';

  @override
  String get settingsSectionStartup => 'Startup';

  @override
  String get settingsLaunchAtLogin => 'Launch at login';

  @override
  String get settingsLaunchAtLoginHint =>
      'Start Glimpr automatically when you log in';

  @override
  String get settingsLanguageAppliesAfterRestart =>
      'Applies after restarting Glimpr';

  @override
  String get settingsRestartNotice => 'Restart Glimpr for this to take effect.';

  @override
  String get settingsRestartNow => 'Restart Glimpr now';

  @override
  String get settingsRestartNowConfirm => 'Click again to restart Glimpr';

  @override
  String get settingsSectionBehaviour => 'Behaviour';

  @override
  String get settingsMousePointer => 'Mouse pointer';

  @override
  String get settingsMousePointerHint =>
      'Include the mouse pointer in screenshots. This is the default; in the screenshot overlay a toolbar button shows/hides it per shot without changing this setting.';

  @override
  String get settingsRightClickExits => 'Right-click exits';

  @override
  String get settingsRightClickExitsHint =>
      'Right-click leaves screenshot mode (Esc always works)';

  @override
  String get settingsConfirmBeforeDiscarding => 'Confirm before discarding';

  @override
  String get settingsConfirmBeforeDiscardingHint =>
      'When exiting a screenshot that still has annotations (right-click or Esc), ask before discarding them.';

  @override
  String get settingsSectionLoupe => 'Loupe';

  @override
  String get settingsLoupeDescription =>
      'Pixel magnifier for crop / blur / pixelate, in the capture overlay and the Image Editor. Nudge the cursor a pixel at a time with the arrow keys.';

  @override
  String get settingsLoupeSize => 'Size';

  @override
  String get settingsLoupeSizeHint => 'Pixels shown per side';

  @override
  String get settingsLoupeMagnification => 'Magnification';

  @override
  String get settingsLoupeMagnificationHint => 'How big each pixel is drawn';

  @override
  String get settingsLoupePreviewReduced => 'Preview reduced to fit';

  @override
  String get settingsLoupeReset => 'Reset';

  @override
  String get settingsToolShortcutsWhileSampling =>
      'Tool shortcuts while sampling';

  @override
  String get settingsToolShortcutsWhileSamplingHint =>
      'Switch tool ends the color-picker sample immediately; Keep sampling ignores tool keys, so a stray key cannot interrupt a careful aim.';

  @override
  String get settingsSwitchTool => 'Switch tool';

  @override
  String get settingsKeepSampling => 'Keep sampling';

  @override
  String get settingsSectionOverlayHUD => 'Overlay HUD';

  @override
  String get settingsCrosshair => 'Crosshair';

  @override
  String get settingsCrosshairHint =>
      'Show the full-screen crosshair lines while aiming with most tools and the colour picker; the reticle stays either way. Toggle it live from the toolbar or a shortcut.';

  @override
  String get settingsLoupeEnable => 'Loupe';

  @override
  String get settingsLoupeEnableHint =>
      'Show the pixel loupe while aiming with most tools and the colour picker; the reticle stays either way. Toggle it live from the toolbar or a shortcut.';

  @override
  String get settingsAnimateMarchingAnts => 'Animate marching ants';

  @override
  String get settingsAnimateMarchingAntsHint =>
      'Flow the dashed selection / crosshair / window outlines. Turn off for static dashes (less motion, slightly lighter).';

  @override
  String get settingsSectionAfterCapture => 'After screenshot';

  @override
  String get settingsSectionAfterEditorDone => 'After Image Editor\'s Done';

  @override
  String get settingsSectionSounds => 'Sounds';

  @override
  String get settingsFlowCopyToClipboard => 'Copy to clipboard';

  @override
  String get settingsFlowCopyToClipboardHint =>
      'Put the image on the clipboard';

  @override
  String get settingsFlowSaveToFile => 'Save to file';

  @override
  String get settingsFlowSaveToFileHint => 'Write the image to the save folder';

  @override
  String get settingsFlowCopyFilePath => 'Copy file path';

  @override
  String get settingsFlowCopyFilePathHint =>
      'Put the saved file\'s path on the clipboard (instead of the image)';

  @override
  String get settingsFlowCopyFilePathNeedsSave => 'Needs \"Save to file\"';

  @override
  String get settingsFlowShowInFinder => 'Show in Finder';

  @override
  String get settingsFlowShowInFinderHint => 'Reveal the saved file in Finder';

  @override
  String get settingsFlowOpenInEditor => 'Open in Image Editor';

  @override
  String get settingsFlowOpenInEditorHint =>
      'Open the result in the Image Editor for further work';

  @override
  String get settingsFlowShareSheet => 'Share sheet';

  @override
  String get settingsFlowShareSheetHint =>
      'Open the macOS share menu (AirDrop, Messages, …)';

  @override
  String get settingsFlowPinToScreen => 'Pin to screen';

  @override
  String get settingsFlowPinToScreenCaptureHint =>
      'Float the screenshot as an always-on-top window, pinned in place over where it was taken';

  @override
  String get settingsFlowPinToScreenEditorHint =>
      'Float the result as an always-on-top window (centered)';

  @override
  String get settingsFlowCaptureCaption =>
      'Runs when a screenshot is confirmed: overlay ✓/Enter and the direct ⌘⌥2/3/4 modes.';

  @override
  String get settingsFlowEditorCaption =>
      'Runs when the Image Editor\'s Done button (or Enter) fires; the ▾ menu beside Done offers one-off alternatives.';

  @override
  String get settingsFlowCaptureCaptionEmpty =>
      'Runs when a screenshot is confirmed: overlay ✓/Enter and the direct ⌘⌥2/3/4 modes. Nothing is selected, so it falls back to Copy to clipboard.';

  @override
  String get settingsFlowEditorCaptionEmpty =>
      'Runs when the Image Editor\'s Done button (or Enter) fires; the ▾ menu beside Done offers one-off alternatives. Nothing is selected, so it falls back to Copy to clipboard.';

  @override
  String get settingsSoundShutter => 'Shutter';

  @override
  String get settingsSoundShutterHint => 'Plays when a capture completes';

  @override
  String get settingsSoundCompletion => 'Completion';

  @override
  String get settingsSoundCompletionHint =>
      'Chimes once the completion flow finishes';

  @override
  String get settingsSectionSaveLocation => 'Save location';

  @override
  String get settingsSectionFormat => 'Format';

  @override
  String get settingsSectionFilename => 'Filename';

  @override
  String get settingsSectionDecoration => 'Decoration';

  @override
  String get settingsSectionRecentHistory => 'Recent history';

  @override
  String get settingsSaveFolder => 'Save folder';

  @override
  String get settingsSaveFolderChoose => 'Choose…';

  @override
  String get settingsSaveFolderReset => 'Reset';

  @override
  String get settingsSaveFolderDefault => 'Default · ~/Pictures/Glimpr';

  @override
  String get settingsFormatQuality => 'Quality';

  @override
  String get settingsFormatQualityHint => 'Compression level';

  @override
  String get settingsFilenamePreview => 'Preview';

  @override
  String get settingsFilenameHint =>
      'Uses the window under the cursor when the screenshot ends; %title and %app are left out on the bare desktop.';

  @override
  String get settingsSectionSubfolder => 'Subfolder';

  @override
  String get settingsInsertVariable => 'Insert variable';

  @override
  String get settingsPatternNormalizeHint =>
      'Reserved characters will be removed on Apply.';

  @override
  String get settingsPreviewCollision => 'If the name is taken';

  @override
  String get settingsPreviewModeWindow => 'Window';

  @override
  String get settingsPreviewModeDisplay => 'Full screen';

  @override
  String get settingsPreviewModeLast => 'Last region';

  @override
  String get settingsPreviewModeRecording => 'Recording';

  @override
  String get settingsPreviewModeDesktop => 'No window';

  @override
  String get settingsSubfolderHint =>
      'Leave empty to save directly in the folder above. Use / for nested folders.';

  @override
  String get tokCatDateTime => 'Date & time';

  @override
  String get tokCatContent => 'Content';

  @override
  String get tokCatCounter => 'Counter';

  @override
  String get tokCatRandom => 'Random';

  @override
  String get tokCatComputer => 'Computer';

  @override
  String get tokYear4 => '4-digit year';

  @override
  String get tokYear2 => '2-digit year';

  @override
  String get tokMonth => 'Month, 01 to 12';

  @override
  String get tokDay => 'Day of month, 01 to 31';

  @override
  String get tokHour24 => 'Hour, 24-hour (00 to 23)';

  @override
  String get tokHour12 => 'Hour, 12-hour (01 to 12)';

  @override
  String get tokMinute => 'Minute, 00 to 59';

  @override
  String get tokSecond => 'Second, 00 to 59';

  @override
  String get tokAmPm => 'AM or PM';

  @override
  String get tokDayOfYear => 'Day of the year, 001 to 366';

  @override
  String get tokWeek => 'ISO week number, 01 to 53';

  @override
  String get tokWeekdayShort => 'Weekday, short (Mon)';

  @override
  String get tokWeekdayFull => 'Weekday, full (Monday)';

  @override
  String get tokMonthShort => 'Month name, short (Jun)';

  @override
  String get tokMonthFull => 'Month name, full (June)';

  @override
  String get tokUnix => 'Unix timestamp (seconds)';

  @override
  String get tokTitle => 'Window title, or the app name if it has none';

  @override
  String get tokApp => 'Application name';

  @override
  String get tokCounter => 'Auto-increment counter; %iN pads to N digits';

  @override
  String get tokRandAlnum => 'Random letters & digits; %raN sets the length';

  @override
  String get tokRandNum => 'Random digits; %rnN sets the length';

  @override
  String get tokRandHex => 'Random hexadecimal; %rxN sets the length';

  @override
  String get tokGuid => 'Random GUID';

  @override
  String get tokHost => 'Computer name';

  @override
  String get tokUser => 'User name';

  @override
  String get settingsFilenamePlaceholders => 'Placeholders';

  @override
  String get settingsFilenameTokenWindowDesc =>
      'The window title, or the app name if it has none';

  @override
  String get settingsFilenameTokenAppDesc =>
      'The application name (e.g. Safari)';

  @override
  String get settingsFilenameTokenDateDesc => 'Capture date, e.g. 2026-06-03';

  @override
  String get settingsFilenameTokenTimeDesc => 'Capture time, e.g. 15-04-09';

  @override
  String settingsFilenameNote(String windowToken, String appToken) {
    return 'Uses the window under the cursor when the screenshot ends. On bare desktop, $windowToken and $appToken are left out.';
  }

  @override
  String get settingsDecorationSnap => 'Snap';

  @override
  String get settingsDecorationSnapHint =>
      'Shadow + margin on a snapped screenshot';

  @override
  String get settingsDecorationFreehandCrop => 'Freehand crop';

  @override
  String get settingsDecorationFreehandCropHint =>
      'Shadow + margin on a dragged crop region';

  @override
  String get settingsDecorationFocusedWindow => 'Focused window';

  @override
  String get settingsDecorationFocusedWindowHint =>
      'Screenshot-window mode (⌘⌥2)';

  @override
  String get settingsDecorationDisplay => 'Display';

  @override
  String get settingsDecorationDisplayHint => 'Screenshot-display mode (⌘⌥3)';

  @override
  String get settingsDecorationLastRegion => 'Last region';

  @override
  String get settingsDecorationLastRegionHint =>
      'Screenshot-last-region mode (⌘⌥4)';

  @override
  String get settingsDecorationJpegFill => 'JPEG background fill';

  @override
  String get settingsDecorationJpegFillHint =>
      'Colour behind the margin when saving as JPEG';

  @override
  String get settingsDecorationPinNote =>
      'Decoration applies to the exported image (file, clipboard, share, editor). Pinned images always use the undecorated original.';

  @override
  String get settingsSectionPin => 'Pin';

  @override
  String get settingsPinHoverGlow => 'Hover glow';

  @override
  String get settingsPinHoverGlowHint =>
      'Show the glowing halo around a pinned window on hover; the controls still appear when off';

  @override
  String get settingsSectionRecording => 'Screen recording';

  @override
  String get settingsRecordingUnavailable =>
      'Screen recording needs macOS 15 or later.';

  @override
  String get settingsRecordingCodec => 'Codec';

  @override
  String get settingsRecordingCodecHint =>
      'H.264 is most compatible; HEVC makes smaller files';

  @override
  String get settingsRecordingFps => 'Frame rate';

  @override
  String get settingsRecordingFpsHint =>
      '60 fps is smoother but roughly doubles the file size';

  @override
  String get settingsRecordingQuality => 'Video quality';

  @override
  String get settingsRecordingQualityHint =>
      'Higher quality looks crisper but makes larger files; applies to mp4 (H.264 / HEVC)';

  @override
  String get settingsRecordingQualityLow => 'Low';

  @override
  String get settingsRecordingQualityMedium => 'Medium';

  @override
  String get settingsRecordingQualityHigh => 'High';

  @override
  String get settingsRecordingResolution => 'Resolution limit';

  @override
  String get settingsRecordingResolutionHint =>
      'Cap the longest side in pixels; larger recordings are downscaled. Video only (GIF is fixed at 1024 px)';

  @override
  String get settingsRecordingResolutionNative => 'Native';

  @override
  String get settingsRecordingGifFpsHint =>
      'Frames per second for GIF recordings; higher is smoother but larger';

  @override
  String get settingsRecordingGifLengthCaution =>
      'GIF holds every frame in memory until it finishes, so a long GIF recording can use several gigabytes and may run out of memory. Keep GIF recordings short.';

  @override
  String get settingsRecordingFormat => 'Format';

  @override
  String get settingsRecordingFormatHint =>
      'H.264 and HEVC are mp4 video; GIF is a silent animated image';

  @override
  String get settingsRecordingCountdown => 'Countdown';

  @override
  String get settingsRecordingCountdownHint =>
      'Wait before recording starts; any recording hotkey cancels the countdown';

  @override
  String get settingsRecordingMaxDuration => 'Stop after';

  @override
  String get settingsRecordingMaxDurationHint =>
      'Automatically stop the recording after this long';

  @override
  String get settingsRecordingDurationOff => 'Off';

  @override
  String get settingsRecordingSecondsSuffix => 's';

  @override
  String get settingsRecordingCursorHint =>
      'Include the mouse pointer in the recording';

  @override
  String get settingsRecordingSystemAudio => 'Record system audio';

  @override
  String get settingsRecordingSystemAudioHint =>
      'Include the sound the system is playing';

  @override
  String get settingsRecordingMicrophone => 'Record microphone';

  @override
  String get settingsRecordingMicrophoneHint =>
      'Asks for microphone permission on first use';

  @override
  String get settingsRecordingMergeAudio => 'Merge audio into one track';

  @override
  String get settingsRecordingMergeAudioHint =>
      'Combine system audio and microphone into a single track for wider compatibility; applies only when both are recorded';

  @override
  String get settingsRecordingDim => 'Dim outside the recording';

  @override
  String get settingsRecordingDimHint =>
      'Darkens the area outside the region and other displays. Turn off for a clear screen during long recordings; the red frame stays.';

  @override
  String get settingsSectionAfterRecording => 'After recording';

  @override
  String get settingsRecentImagesKept => 'Recent images kept';

  @override
  String get settingsRecentImagesKeptHint =>
      'How many images the landing gallery and the menu-bar Open Recent keep.';

  @override
  String get settingsSectionMultiDisplay => 'Multi-display';

  @override
  String get settingsWarmEnginesTitle => 'Warm screenshot engines';

  @override
  String get settingsWarmEnginesBody =>
      'How many displays Glimpr keeps instantly screenshot-ready, including displays connected after the app has launched (e.g. plugging into a dock). Glimpr pre-warms a rendering engine per display so the freeze overlay appears with no delay.\n\nThis is a minimum, not a cap: every display already connected when Glimpr starts gets a warm engine regardless of this number; it only adds spares for displays plugged in later.\n\nCost: each engine uses about 10 MB of memory while Glimpr runs. A display plugged in beyond this number still screenshots, but only shows the frozen frame; its crosshair and toolbar follow correctly after a restart (which makes every connected display warm again).';

  @override
  String get settingsWarmEnginesDefault =>
      'Default 2 · applies after restarting Glimpr';

  @override
  String get settingsSectionCaptureLayers => 'Screenshot layers';

  @override
  String get settingsCaptureLayersTitle => 'Screenshot layers';

  @override
  String get settingsCaptureLayersBody =>
      'Press the screenshot shortcut while a screenshot is already open to stack a new freeze on top (the previous layer stays in the screenshot, annotations and all); finishing or cancelling a layer returns to the one below.\n\nWith 1 (the default) nothing stacks: a new trigger restarts the screenshot. With 2 to 5, the OLDEST layer is dropped once the cap is reached, keeping the most recent ones; the toolbar announces both cases.\n\nCost: each stacked layer holds a full-resolution frozen image per display (roughly 30 to 60 MB at 4K or 5K) while the session is open. Applies on the next screenshot; no restart needed.';

  @override
  String get settingsSectionElementSnap => 'Element snap';

  @override
  String get settingsElementSnapTitle => 'Precise element snap (experimental)';

  @override
  String get settingsElementSnapBody =>
      'Snap to the UI element under the cursor (a button, a pane, a list row) instead of the whole window. Works for both screenshots and recording region select; use the scroll wheel to grow or shrink the selection along the element tree.\n\nNeeds Accessibility permission, which lets Glimpr read the on-screen UI of other apps system-wide (not only while capturing). Each hover runs a live query (typically a few milliseconds, a little more on a busy app) versus none for plain window snap; it runs off the render thread, so it never stalls the overlay. How finely an app can be snapped is up to that app: native apps expose detailed elements, while some browsers, Electron, custom-drawn or game interfaces expose little and fall back to window snap. The captured region is the element\'s reported bounds, so it can include the element\'s own padding. Experimental: the highlight is queried live, so it may briefly differ from the frozen screenshot if a window moves underneath.';

  @override
  String get settingsElementSnapNeedsPermission =>
      'Accessibility permission not granted';

  @override
  String get settingsElementSnapGrant => 'Grant…';

  @override
  String elementSnapLevelLabel(String lvl) {
    return 'Element level $lvl';
  }

  @override
  String get loupeShortcutWalkKey => 'Scroll or , .';

  @override
  String get loupeShortcutWalkDesc => 'element level';

  @override
  String get loupeShortcutNudgeKey => 'Arrow keys';

  @override
  String get loupeShortcutNudgeDesc => 'nudge';

  @override
  String get loupeShortcutAngleKey => 'Shift';

  @override
  String get loupeShortcutSquareDesc => 'square';

  @override
  String get loupeShortcutCircleDesc => 'circle';

  @override
  String get loupeShortcut45Desc => '45°';

  @override
  String get loupeShortcutCopyHexDesc => 'copy HEX';

  @override
  String get loupeShortcutCopyRgbDesc => 'copy RGB';

  @override
  String get loupeShortcutCopyHslDesc => 'copy HSL';

  @override
  String get settingsCycleLoupeInfo => 'Cycle loupe info';

  @override
  String get settingsCycleLoupeInfoHint =>
      'Cycle what the loupe shows: coordinates, element level, shortcuts, hidden.';

  @override
  String get settingsReservedElementSnapLevel => 'Element snap level';

  @override
  String get settingsReservedElementSnapLevelHint =>
      'While precise element snap is on, , and . (or the scroll wheel) shrink and grow the snapped element along its tree.';

  @override
  String get elementSnapLevelDefault => 'auto';

  @override
  String elementSnapLevelOut(int n) {
    return 'out $n';
  }

  @override
  String elementSnapLevelIn(int n) {
    return 'in $n';
  }

  @override
  String get settingsSectionToolStyles => 'Tool styles';

  @override
  String get settingsResetAllToolStyles => 'Reset all tool styles';

  @override
  String get settingsResetAllToolStylesHint =>
      'Restore every annotation tool (colour, stroke, font size, font) to its default. Takes effect on your next screenshot.';

  @override
  String get settingsResetAllToolStylesConfirm =>
      'Click again to reset all tool styles';

  @override
  String get settingsShortcutsCaptureNote =>
      'Fire globally, so they need a modifier (⌘ ⌥ ⌃ ⇧)';

  @override
  String get settingsShortcutsRecordingNote =>
      'While recording, any recording hotkey stops it (not cancel); screenshot hotkeys still work, so you can capture a still while recording';

  @override
  String get settingsCmdUndo => 'Undo';

  @override
  String get settingsCmdRedo => 'Redo';

  @override
  String get settingsCmdPasteImage => 'Paste image';

  @override
  String get settingsCmdPasteImageHint => 'From the clipboard';

  @override
  String get settingsCmdDeleteSelected => 'Delete selected';

  @override
  String get settingsCmdDeleteSelectedHint => 'Remove the selected annotation';

  @override
  String get settingsCmdExport => 'Export';

  @override
  String get settingsCmdExportHint =>
      'Screenshot the snapped window, or the whole screen';

  @override
  String get settingsCmdDuplicateSelected => 'Duplicate selected';

  @override
  String get settingsCmdDuplicateSelectedHint => 'Copy the selected annotation';

  @override
  String get settingsCmdBringToFront => 'Bring to front';

  @override
  String get settingsCmdBringToFrontHint => 'Move the selection above others';

  @override
  String get settingsCmdSendToBack => 'Send to back';

  @override
  String get settingsCmdSendToBackHint => 'Move the selection below others';

  @override
  String get settingsCmdCopyHex => 'Copy color as HEX';

  @override
  String get settingsCmdCopyColorHint => 'While the color picker is sampling';

  @override
  String get settingsCmdCopyRgb => 'Copy color as RGB';

  @override
  String get settingsCmdCopyHsl => 'Copy color as HSL';

  @override
  String get settingsCmdToggleCrosshair => 'Toggle crosshair';

  @override
  String get settingsCmdToggleCrosshairHint =>
      'Show or hide the crosshair lines for the current session';

  @override
  String get settingsCmdToggleLoupe => 'Toggle loupe';

  @override
  String get settingsCmdToggleLoupeHint =>
      'Show or hide the pixel loupe for the current session';

  @override
  String get settingsReservedCancelExit => 'Cancel / Exit';

  @override
  String get settingsReservedHint => 'Reserved';

  @override
  String get settingsReservedCloseWindow => 'Close window';

  @override
  String get settingsReservedHintEditorSettings =>
      'Reserved · editor / settings';

  @override
  String get settingsReservedOpenSettings => 'Open Settings';

  @override
  String get settingsReservedHintOverlayEditor => 'Reserved · overlay / editor';

  @override
  String get settingsReservedNudgeCrosshair => 'Nudge crosshair';

  @override
  String get settingsReservedHintRegionTools => 'Reserved · region tools';

  @override
  String get settingsReservedFitToWindow => 'Fit to window';

  @override
  String get settingsReservedHintImageEditor => 'Reserved · image editor';

  @override
  String get settingsReservedZoomTo100 => 'Zoom to 100%';

  @override
  String get settingsReservedCommitText => 'Commit text';

  @override
  String get settingsReservedHintWhileEditingText =>
      'Reserved · while editing text';

  @override
  String get settingsReservedNewLine => 'New line';

  @override
  String get settingsReservedCancelText => 'Cancel text';

  @override
  String get settingsShortcutsNeedsModifier => 'Needs a modifier';

  @override
  String get settingsShortcutsDuplicate => 'Duplicate';

  @override
  String get settingsShortcutsResetToDefault => 'Reset to default';

  @override
  String get settingsShortcutsRevert => 'Revert';

  @override
  String get settingsShortcutsApply => 'Apply';

  @override
  String get settingsShortcutsTools => 'Tools';

  @override
  String get settingsShortcutsCommands => 'Commands';

  @override
  String get settingsShortcutsReserved => 'Reserved';

  @override
  String get scopeGlobal => 'Global';

  @override
  String get scopeEditor => 'Editor';

  @override
  String get scopeOverlay => 'Overlay';

  @override
  String get scopeImage => 'Image';

  @override
  String get scopeText => 'Text';

  @override
  String get scopeGlobalDesc => 'System-wide hotkeys';

  @override
  String get scopeEditorDesc => 'Capture overlay and image editor';

  @override
  String get scopeOverlayDesc => 'Capture overlay only';

  @override
  String get scopeImageDesc => 'Image editor only';

  @override
  String get scopeTextDesc => 'While editing a text annotation';

  @override
  String get shortcutsLegendDedup =>
      'Every shortcut must be unique across the whole page, so a key combination can\'t be used twice and reserved keys can\'t be reassigned. The tag on each row shows where it applies:';

  @override
  String get actionCapture => 'Screenshot Region';

  @override
  String get actionCaptureHint =>
      'Select a region and screenshot it; press again to stack';

  @override
  String get actionCaptureWindow => 'Screenshot Window';

  @override
  String get actionCaptureWindowHint => 'Screenshot the focused window';

  @override
  String get actionCaptureDisplay => 'Screenshot Display';

  @override
  String get actionCaptureDisplayHint =>
      'Screenshot the display under the cursor';

  @override
  String get actionCaptureLastRegion => 'Screenshot Last Region';

  @override
  String get actionCaptureLastRegionHint => 'Repeat the last screenshot region';

  @override
  String get actionOpenEditor => 'Open Image Editor';

  @override
  String get actionOpenEditorHint => 'Open the Image Editor';

  @override
  String get actionOpenEditorClipboard => 'Open Image Editor with Clipboard';

  @override
  String get actionOpenEditorClipboardHint =>
      'Open the Image Editor and load the clipboard image';

  @override
  String get actionPinCapture => 'Pin Screenshot';

  @override
  String get actionPinCaptureHint =>
      'Screenshot a region straight to a floating pin';

  @override
  String get actionPinClipboard => 'Pin Clipboard';

  @override
  String get actionPinClipboardHint => 'Float the clipboard image as a pin';

  @override
  String get actionRecordRegion => 'Record Region';

  @override
  String get actionRecordRegionHint =>
      'Record a screen region; press again to stop';

  @override
  String get actionRecordWindow => 'Record Window';

  @override
  String get actionRecordWindowHint =>
      'Record the focused window; press again to stop';

  @override
  String get actionRecordDisplay => 'Record Display';

  @override
  String get actionRecordDisplayHint =>
      'Record the display under the cursor; press again to stop';

  @override
  String get actionRecordLastRegion => 'Record Last Region';

  @override
  String get actionRecordLastRegionHint =>
      'Repeat the last recording region; press again to stop';

  @override
  String get toolSelect => 'Select';

  @override
  String get toolCrop => 'Crop';

  @override
  String get toolPin => 'Pin';

  @override
  String get toolRecord => 'Record';

  @override
  String get toolCropPinCombined => 'Crop / Pin / Record';

  @override
  String get toolBlur => 'Blur';

  @override
  String get toolPixelate => 'Pixelate';

  @override
  String get toolRectangle => 'Rectangle';

  @override
  String get toolEllipse => 'Ellipse';

  @override
  String get toolLine => 'Line';

  @override
  String get toolArrow => 'Arrow';

  @override
  String get toolPen => 'Pen';

  @override
  String get toolText => 'Text';

  @override
  String get toolHighlighter => 'Highlighter';

  @override
  String get toolStep => 'Numbered step';

  @override
  String get toolStamp => 'Image stamp';

  @override
  String get toolMagnify => 'Magnify';

  @override
  String get toolSpotlight => 'Spotlight';

  @override
  String get toolbarPinCaption => 'Pin mode: the selection floats as a pin';

  @override
  String get toolbarRecordCaption =>
      'Record mode: the selection starts a recording';

  @override
  String get toolbarRecordCodec => 'Codec (this recording)';

  @override
  String get toolbarRecordFps => 'Frame rate (this recording)';

  @override
  String get toolbarRecordCursor => 'Show cursor (this recording)';

  @override
  String get toolbarRecordSystemAudio => 'System audio (this recording)';

  @override
  String get toolbarRecordMicrophone => 'Microphone (this recording)';

  @override
  String get toolbarCrosshairShown => 'Crosshair lines: shown';

  @override
  String get toolbarCrosshairHidden => 'Crosshair lines: hidden';

  @override
  String get toolbarLoupeShown => 'Pixel loupe: shown';

  @override
  String get toolbarLoupeHidden => 'Pixel loupe: hidden';

  @override
  String get toolbarMousePointerShown => 'Mouse pointer: shown';

  @override
  String get toolbarMousePointerHidden => 'Mouse pointer: hidden';

  @override
  String get toolbarChooseImage => 'Choose image…';

  @override
  String get toolbarChangeImage => 'Change image…';

  @override
  String get toolbarChooseStampImage => 'Choose a stamp image';

  @override
  String get toolbarFillBackground => 'Background';

  @override
  String get toolbarFill => 'Fill';

  @override
  String get toolbarTextOutline => 'Text outline';

  @override
  String get toolbarColour => 'Colour';

  @override
  String get toolbarBlurStrength => 'Blur strength';

  @override
  String get toolbarPixelSize => 'Pixel size';

  @override
  String get toolbarStrokeWidth => 'Stroke width';

  @override
  String toolbarRadiusLabel(String value) {
    return 'Radius: $value';
  }

  @override
  String get toolbarCornerRadius => 'Corner radius';

  @override
  String get toolbarHighlighterTexture => 'Highlighter texture';

  @override
  String get toolbarLineStyle => 'Line style';

  @override
  String get toolbarCurvePoints => 'Curve points';

  @override
  String get toolbarArrowheads => 'Arrowheads';

  @override
  String get toolbarArrowheadSize => 'Arrowhead size';

  @override
  String get toolbarFontSize => 'Font size';

  @override
  String get toolbarBadgeSize => 'Badge size';

  @override
  String get toolbarStartNumber => 'Start number';

  @override
  String get toolbarBadgeShape => 'Badge shape';

  @override
  String get toolbarFontSystem => 'System';

  @override
  String get toolbarBackgroundDim => 'Background dim';

  @override
  String get toolbarBackgroundTreatment => 'Background treatment';

  @override
  String get toolbarEdgeFeather => 'Edge feather';

  @override
  String get toolbarMagnification => 'Magnification';

  @override
  String get toolbarDropShadowOn => 'Drop shadow: on';

  @override
  String get toolbarDropShadowOff => 'Drop shadow: off';

  @override
  String get toolbarConnectorLineOn => 'Connector line: on';

  @override
  String get toolbarConnectorLineOff => 'Connector line: off';

  @override
  String get toolbarResetThisTool => 'Reset this tool';

  @override
  String get toolbarDuplicate => 'Duplicate';

  @override
  String get toolbarBringToFront => 'Bring to front';

  @override
  String get toolbarSendToBack => 'Send to back';

  @override
  String get popoverSearchFonts => 'Search fonts…';

  @override
  String get popoverFontSystem => 'System';

  @override
  String get lineStyleSolid => 'Solid';

  @override
  String get lineStyleDashed => 'Dashed';

  @override
  String get lineStyleDotted => 'Dotted';

  @override
  String get lineStyleLongDash => 'Long dash';

  @override
  String get lineStyleDashDot => 'Dash-dot';

  @override
  String get lineStyleDashDotDot => 'Dash-dot-dot';

  @override
  String get popoverTextureClean => 'Clean';

  @override
  String get popoverTextureStreaks => 'Streaks';

  @override
  String get popoverTextureFraged => 'Frayed';

  @override
  String get popoverArrowHeadEnd => 'End';

  @override
  String get popoverArrowHeadStart => 'Start';

  @override
  String get popoverArrowHeadBoth => 'Both';

  @override
  String get popoverStepShapeCircle => 'Circle';

  @override
  String get popoverStepShapeSquare => 'Square';

  @override
  String get popoverSpotlightEffectDimOnly => 'Dim only';

  @override
  String get popoverSpotlightEffectDimBlur => 'Dim + Blur';

  @override
  String get popoverSpotlightEffectDimPixelate => 'Dim + Pixelate';

  @override
  String get popoverPickColourFromScreen => 'Pick a colour from the screen';

  @override
  String get popoverCornerRadius => 'Corner radius';

  @override
  String get popoverRadiusAuto => 'Auto';

  @override
  String get popoverRadiusAutoHint => 'Radius scales with the rectangle’s size';

  @override
  String get editorTitleBar => 'Image Editor';

  @override
  String get editorOpenImage => 'Open an image to edit';

  @override
  String get editorOpenImageSubtitle =>
      'Annotate, crop, and re-export any image in the same toolkit you use to screenshot.';

  @override
  String get editorOpenImageButton => 'Open Image…';

  @override
  String get editorOpenImageHint => 'or drag an image here · paste with ⌘V';

  @override
  String get editorGalleryRecent => 'Recent';

  @override
  String get editorGalleryMoreTooltip => 'Open the save folder in Finder';

  @override
  String get editorGalleryMoreCaption => 'More…';

  @override
  String get editorGalleryHome => 'Home';

  @override
  String get editorContextEdit => 'Edit';

  @override
  String get editorContextCopyImage => 'Copy Image';

  @override
  String get editorContextCopyPath => 'Copy Path';

  @override
  String get editorContextShare => 'Share…';

  @override
  String get editorContextPinToScreen => 'Pin to Screen';

  @override
  String get editorContextShowInFinder => 'Show in Finder';

  @override
  String get editorContextRemoveFromRecent => 'Remove from Recent';

  @override
  String get editorContextClearRecent => 'Clear Recent';

  @override
  String get editorClearRecentTitle => 'Clear Recent?';

  @override
  String editorClearRecentMessage(int count) {
    return 'Remove all $count entries from the recent list? The image files themselves are not touched.';
  }

  @override
  String get editorClearRecentConfirm => 'Clear';

  @override
  String get editorToastCopiedToClipboard => 'Copied to clipboard';

  @override
  String get editorToastCopyFailed => 'Copy failed';

  @override
  String get editorToastPathCopied => 'Path copied';

  @override
  String get editorToastNoImageInClipboard => 'No image in clipboard';

  @override
  String get editorToastCannotDecodeClipboard =>
      'Cannot decode clipboard image';

  @override
  String editorToastCannotReadFile(String error) {
    return 'Cannot read file: $error';
  }

  @override
  String editorToastCannotDecodeImage(String error) {
    return 'Cannot decode image: $error';
  }

  @override
  String get editorToastCopied => 'Copied';

  @override
  String get editorToastCopyFlowFailed => 'Copy failed';

  @override
  String editorToastSavedTo(String path) {
    return 'Saved to $path';
  }

  @override
  String get editorToastSaveFailed => 'Save failed';

  @override
  String get editorToastCopyPathFailed => 'Copy path failed';

  @override
  String get editorToastRevealFailed => 'Reveal failed';

  @override
  String get editorToastShareFailed => 'Share failed';

  @override
  String get editorToastPinFailed => 'Pin failed';

  @override
  String get editorToastPinned => 'Pinned';

  @override
  String get editorToastDone => 'Done';

  @override
  String get editorDiscardTitle => 'Discard changes?';

  @override
  String get editorDiscardMessage =>
      'You have unsaved annotations. Discard them?';

  @override
  String get editorDoneButton => 'Done';

  @override
  String get editorMenuOneOffTooltip =>
      'One-off action (instead of the Done flow)';

  @override
  String get editorMenuCopyOnly => 'Copy only';

  @override
  String get editorMenuSaveOnly => 'Save only';

  @override
  String get editorMenuCopyFilePath => 'Copy file path';

  @override
  String get editorMenuShowInFinder => 'Show in Finder';

  @override
  String get editorMenuShare => 'Share…';

  @override
  String get editorMenuPinToScreen => 'Pin to screen';

  @override
  String get editorViewFitToWindow => 'Fit to window (⌘1)';

  @override
  String get editorViewActualSize => 'Actual size · 100% (⌘2)';

  @override
  String get editorUndoTooltip => 'Undo';

  @override
  String get editorRedoTooltip => 'Redo';

  @override
  String get editorCropConfirm => 'Crop (Enter)';

  @override
  String get editorCropCancel => 'Cancel (Esc)';

  @override
  String get maskSettingsOpen => 'Settings open';

  @override
  String get maskSettingsOpenHint => 'Close the Settings window to continue.';

  @override
  String get confirmDiscardTitle => 'Discard changes?';

  @override
  String get confirmDiscardMessage =>
      'You have unsaved annotations. Discard them?';

  @override
  String get confirmDiscard => 'Discard';

  @override
  String get confirmCancel => 'Cancel';

  @override
  String get recorderDisabled => 'Disabled';

  @override
  String get recorderReservedKey => 'Reserved key';

  @override
  String get recorderNeedsModifier => 'Needs a modifier (⌘ ⌥ ⌃ ⇧)';

  @override
  String get recorderDisable => 'Disable';

  @override
  String get recorderPressKeys => 'Press keys…';

  @override
  String get recorderEscToCancel => 'Press Esc to cancel';

  @override
  String layersCaption(int depth, int cap) {
    return 'Layers: $depth/$cap';
  }

  @override
  String layerReplacedNotice(int depth, int cap) {
    return 'Layer replaced ($depth/$cap)';
  }

  @override
  String oldestLayerDroppedNotice(int depth, int cap) {
    return 'Oldest layer dropped ($depth/$cap)';
  }

  @override
  String get overlayDiscardLayerTitle => 'Discard this layer?';

  @override
  String get overlayDiscardLayerMessage =>
      'You have unsaved annotations on this layer. Discard them and return to the layer below?';

  @override
  String get overlayDiscardCaptureTitle => 'Discard screenshot?';

  @override
  String get overlayDiscardCaptureMessage =>
      'You have unsaved annotations on this screenshot. Discard them and exit?';

  @override
  String get overlayPinFailed => 'Pin failed';

  @override
  String overlayCaptureFailedError(String error) {
    return 'Screenshot failed: $error';
  }

  @override
  String get overlayFailedNotSavedOrCopied =>
      'Screenshot failed: not saved or copied';

  @override
  String get overlayFailedSave => 'Copied, but file save failed';

  @override
  String get overlayFailedClipboard => 'Saved, but clipboard failed';

  @override
  String get overlayCaptureFailedGeneric => 'Screenshot failed';

  @override
  String get keyCapNone => 'None';
}
