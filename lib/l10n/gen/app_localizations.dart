import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'gen/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('zh'),
  ];

  /// Settings > General: the app language picker section label and card title
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get settingsLanguage;

  /// Settings sidebar: General pane label
  ///
  /// In en, this message translates to:
  /// **'General'**
  String get settingsPaneGeneral;

  /// Settings sidebar: Capture pane label
  ///
  /// In en, this message translates to:
  /// **'Screenshot'**
  String get settingsPaneCapture;

  /// Settings sidebar: screen recording pane title
  ///
  /// In en, this message translates to:
  /// **'Recording'**
  String get settingsPaneRecording;

  /// Settings sidebar: Output pane label
  ///
  /// In en, this message translates to:
  /// **'Output'**
  String get settingsPaneOutput;

  /// Settings sidebar: Shortcuts pane label
  ///
  /// In en, this message translates to:
  /// **'Shortcuts'**
  String get settingsPaneShortcuts;

  /// Settings sidebar: Advanced pane label
  ///
  /// In en, this message translates to:
  /// **'Advanced'**
  String get settingsPaneAdvanced;

  /// Settings sidebar: About pane label
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get settingsPaneAbout;

  /// About pane: link to the creator's Ko-fi tip page (Ko-fi brand logo leads the row)
  ///
  /// In en, this message translates to:
  /// **'Support'**
  String get settingsAboutKofi;

  /// About pane: link to the GitHub repository (GitHub brand logo leads the row)
  ///
  /// In en, this message translates to:
  /// **'Source code'**
  String get settingsAboutGithub;

  /// About pane: link to the official website
  ///
  /// In en, this message translates to:
  /// **'Website'**
  String get settingsAboutWebsite;

  /// About pane: opens the in-app open-source license page
  ///
  /// In en, this message translates to:
  /// **'Licenses & acknowledgements'**
  String get settingsAboutLicenses;

  /// About pane: manual update-check row label (idle state)
  ///
  /// In en, this message translates to:
  /// **'Check for updates'**
  String get settingsAboutCheckUpdates;

  /// About pane: update row label while the check is in flight
  ///
  /// In en, this message translates to:
  /// **'Checking...'**
  String get settingsAboutChecking;

  /// About pane: update row label when a newer release exists; tapping opens the download page
  ///
  /// In en, this message translates to:
  /// **'Update available: {version}'**
  String settingsAboutUpdateAvailable(String version);

  /// About pane: update row label right after a manual check found no newer release
  ///
  /// In en, this message translates to:
  /// **'You are up to date'**
  String get settingsAboutUpToDate;

  /// About pane: status while the self-update downloads the new release
  ///
  /// In en, this message translates to:
  /// **'Downloading the update…'**
  String get settingsAboutUpdateDownloading;

  /// About pane: status while the self-update installs; the app restarts on its own
  ///
  /// In en, this message translates to:
  /// **'Installing, the app will restart…'**
  String get settingsAboutUpdateInstalling;

  /// Advanced pane: updates section label
  ///
  /// In en, this message translates to:
  /// **'Updates'**
  String get settingsSectionUpdates;

  /// Advanced pane: auto update-check toggle title
  ///
  /// In en, this message translates to:
  /// **'Check for updates automatically'**
  String get settingsUpdateCheckTitle;

  /// Advanced pane: auto update-check toggle explanation
  ///
  /// In en, this message translates to:
  /// **'Once a day, Glimpr asks GitHub whether a newer release exists. Nothing else is sent.'**
  String get settingsUpdateCheckBody;

  /// About > Licenses: number of licenses a package has
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =1{1 license} other{{count} licenses}}'**
  String settingsLicenseCount(int count);

  /// Settings sidebar: Image Editor pane label
  ///
  /// In en, this message translates to:
  /// **'Image Editor'**
  String get settingsPaneImageEditor;

  /// Settings sidebar: shared Selection & HUD pane label
  ///
  /// In en, this message translates to:
  /// **'Selection & HUD'**
  String get settingsPaneSelectionHud;

  /// Settings > General: Startup section label
  ///
  /// In en, this message translates to:
  /// **'Startup'**
  String get settingsSectionStartup;

  /// Settings > General > Startup: launch at login toggle title
  ///
  /// In en, this message translates to:
  /// **'Launch at login'**
  String get settingsLaunchAtLogin;

  /// Settings > General > Startup: launch at login toggle hint
  ///
  /// In en, this message translates to:
  /// **'Start Glimpr automatically when you log in'**
  String get settingsLaunchAtLoginHint;

  /// Settings > General > Language: subtitle below the language picker
  ///
  /// In en, this message translates to:
  /// **'Applies after restarting Glimpr'**
  String get settingsLanguageAppliesAfterRestart;

  /// Settings > General/Advanced: warning shown when a restart-required setting changes
  ///
  /// In en, this message translates to:
  /// **'Restart Glimpr for this to take effect.'**
  String get settingsRestartNotice;

  /// Settings > General/Advanced: restart button label (first click)
  ///
  /// In en, this message translates to:
  /// **'Restart Glimpr now'**
  String get settingsRestartNow;

  /// Settings > General/Advanced: restart button confirm label (second click)
  ///
  /// In en, this message translates to:
  /// **'Click again to restart Glimpr'**
  String get settingsRestartNowConfirm;

  /// Windows system-tray menu: Open Recent submenu title
  ///
  /// In en, this message translates to:
  /// **'Open Recent'**
  String get trayOpenRecent;

  /// Windows system-tray menu: clear the recent-images list
  ///
  /// In en, this message translates to:
  /// **'Clear Recent'**
  String get trayClearRecent;

  /// Windows system-tray menu: open the save folder
  ///
  /// In en, this message translates to:
  /// **'Open Save Folder'**
  String get trayOpenSaveFolder;

  /// Windows system-tray menu: About item
  ///
  /// In en, this message translates to:
  /// **'About Glimpr'**
  String get trayAbout;

  /// Windows system-tray menu: Settings item
  ///
  /// In en, this message translates to:
  /// **'Settings...'**
  String get traySettings;

  /// Windows system-tray menu: Quit item
  ///
  /// In en, this message translates to:
  /// **'Quit Glimpr'**
  String get trayQuit;

  /// Menu-bar / tray icon tooltip while the processing pulse runs for a screenshot
  ///
  /// In en, this message translates to:
  /// **'Processing screenshot…'**
  String get trayProcessingScreenshot;

  /// Menu-bar / tray icon tooltip while the processing pulse runs for a recording finalize
  ///
  /// In en, this message translates to:
  /// **'Processing recording…'**
  String get trayProcessingRecording;

  /// Menu-bar / tray icon tooltip while the processing pulse runs for an editor Done export
  ///
  /// In en, this message translates to:
  /// **'Processing image…'**
  String get trayProcessingImage;

  /// Settings > Capture: Behaviour section label
  ///
  /// In en, this message translates to:
  /// **'Behaviour'**
  String get settingsSectionBehaviour;

  /// Settings > Screenshot > Format: dual-output HDR screenshot toggle title
  ///
  /// In en, this message translates to:
  /// **'Save HDR screenshots'**
  String get settingsHdrScreenshot;

  /// Settings > Screenshot > Format: dual-output HDR screenshot toggle hint (macOS wording)
  ///
  /// In en, this message translates to:
  /// **'On an HDR display, screenshots also save an HDR HEIC file beside the standard image (macOS 26 or later): annotations included; a toolbar button can skip it per shot. The clipboard and editor keep the standard image.'**
  String get settingsHdrScreenshotHintMac;

  /// Settings > Screenshot > Format: dual-output HDR screenshot toggle hint (Windows wording)
  ///
  /// In en, this message translates to:
  /// **'On an HDR display, screenshots also save an HDR JPEG XR file beside the standard image: annotations included; a toolbar button can skip it per shot. The clipboard and editor keep the standard image.'**
  String get settingsHdrScreenshotHintWindows;

  /// Overlay toolbar HDR toggle tooltip while ON (this capture also writes the HDR sibling file)
  ///
  /// In en, this message translates to:
  /// **'HDR file: on for this shot'**
  String get toolbarHdrOn;

  /// Overlay toolbar HDR toggle tooltip while OFF (this capture skips the HDR sibling file)
  ///
  /// In en, this message translates to:
  /// **'HDR file: off for this shot'**
  String get toolbarHdrOff;

  /// Settings > Capture > Behaviour: mouse pointer toggle title
  ///
  /// In en, this message translates to:
  /// **'Mouse pointer'**
  String get settingsMousePointer;

  /// Settings > Capture > Behaviour: mouse pointer toggle hint
  ///
  /// In en, this message translates to:
  /// **'Include the mouse pointer in screenshots. This is the default; in the screenshot overlay a toolbar button shows/hides it per shot without changing this setting.'**
  String get settingsMousePointerHint;

  /// Settings > Capture > Behaviour: right-click exits toggle title
  ///
  /// In en, this message translates to:
  /// **'Right-click exits'**
  String get settingsRightClickExits;

  /// Settings > Capture > Behaviour: right-click exits toggle hint
  ///
  /// In en, this message translates to:
  /// **'Right-click leaves screenshot mode (Esc always works)'**
  String get settingsRightClickExitsHint;

  /// Settings > Capture > Behaviour: confirm on exit toggle title
  ///
  /// In en, this message translates to:
  /// **'Confirm before discarding'**
  String get settingsConfirmBeforeDiscarding;

  /// Settings > Capture > Behaviour: confirm on exit toggle hint
  ///
  /// In en, this message translates to:
  /// **'When exiting a screenshot that still has annotations (right-click or Esc), ask before discarding them.'**
  String get settingsConfirmBeforeDiscardingHint;

  /// Settings > Capture: Loupe section label
  ///
  /// In en, this message translates to:
  /// **'Loupe'**
  String get settingsSectionLoupe;

  /// Settings > Capture > Loupe: introductory description
  ///
  /// In en, this message translates to:
  /// **'Pixel magnifier for crop / blur / pixelate, in the capture overlay and the Image Editor. Nudge the cursor a pixel at a time with the arrow keys.'**
  String get settingsLoupeDescription;

  /// Settings > Capture > Loupe: size slider title
  ///
  /// In en, this message translates to:
  /// **'Size'**
  String get settingsLoupeSize;

  /// Settings > Capture > Loupe: size slider hint
  ///
  /// In en, this message translates to:
  /// **'Pixels shown per side'**
  String get settingsLoupeSizeHint;

  /// Settings > Capture > Loupe: magnification slider title
  ///
  /// In en, this message translates to:
  /// **'Magnification'**
  String get settingsLoupeMagnification;

  /// Settings > Capture > Loupe: magnification slider hint
  ///
  /// In en, this message translates to:
  /// **'How big each pixel is drawn'**
  String get settingsLoupeMagnificationHint;

  /// Settings > Capture > Loupe: note shown when preview is scaled down
  ///
  /// In en, this message translates to:
  /// **'Preview reduced to fit'**
  String get settingsLoupePreviewReduced;

  /// Settings > Capture > Loupe: reset button label
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get settingsLoupeReset;

  /// Settings > Capture: eyedropper tool-switch behavior row title
  ///
  /// In en, this message translates to:
  /// **'Tool shortcuts while sampling'**
  String get settingsToolShortcutsWhileSampling;

  /// Settings > Capture: eyedropper tool-switch behavior row hint
  ///
  /// In en, this message translates to:
  /// **'Switch tool ends the color-picker sample immediately; Keep sampling ignores tool keys, so a stray key cannot interrupt a careful aim.'**
  String get settingsToolShortcutsWhileSamplingHint;

  /// Settings > Capture: eyedropper keys-cancel segmented option
  ///
  /// In en, this message translates to:
  /// **'Switch tool'**
  String get settingsSwitchTool;

  /// Settings > Capture: eyedropper keep-sampling segmented option
  ///
  /// In en, this message translates to:
  /// **'Keep sampling'**
  String get settingsKeepSampling;

  /// Settings > Capture: Overlay HUD section label
  ///
  /// In en, this message translates to:
  /// **'Overlay HUD'**
  String get settingsSectionOverlayHUD;

  /// Settings > Capture > Overlay HUD: crosshair toggle title
  ///
  /// In en, this message translates to:
  /// **'Crosshair'**
  String get settingsCrosshair;

  /// Settings > Capture > Overlay HUD: crosshair toggle hint
  ///
  /// In en, this message translates to:
  /// **'Show the full-screen crosshair lines while aiming with most tools and the colour picker; the reticle stays either way. Toggle it live from the toolbar or a shortcut.'**
  String get settingsCrosshairHint;

  /// Settings > Capture > Overlay HUD: loupe (magnifier) toggle title
  ///
  /// In en, this message translates to:
  /// **'Loupe'**
  String get settingsLoupeEnable;

  /// Settings > Capture > Overlay HUD: loupe toggle hint
  ///
  /// In en, this message translates to:
  /// **'Show the pixel loupe while aiming with most tools and the colour picker; the reticle stays either way. Toggle it live from the toolbar or a shortcut.'**
  String get settingsLoupeEnableHint;

  /// Settings > Capture > Overlay HUD: marching ants toggle title
  ///
  /// In en, this message translates to:
  /// **'Animate marching ants'**
  String get settingsAnimateMarchingAnts;

  /// Settings > Capture > Overlay HUD: marching ants toggle hint
  ///
  /// In en, this message translates to:
  /// **'Flow the dashed selection / crosshair / window outlines. Turn off for static dashes (less motion, slightly lighter).'**
  String get settingsAnimateMarchingAntsHint;

  /// Settings > Workflow: After capture section label
  ///
  /// In en, this message translates to:
  /// **'After screenshot'**
  String get settingsSectionAfterCapture;

  /// Settings > Workflow: After editor's Done section label
  ///
  /// In en, this message translates to:
  /// **'After Image Editor\'s Done'**
  String get settingsSectionAfterEditorDone;

  /// Settings > Workflow: Sounds section label
  ///
  /// In en, this message translates to:
  /// **'Sounds'**
  String get settingsSectionSounds;

  /// Settings > Workflow: copy-to-clipboard flow action row title
  ///
  /// In en, this message translates to:
  /// **'Copy to clipboard'**
  String get settingsFlowCopyToClipboard;

  /// Settings > Workflow: copy-to-clipboard flow action row hint
  ///
  /// In en, this message translates to:
  /// **'Put the image on the clipboard'**
  String get settingsFlowCopyToClipboardHint;

  /// Settings > Workflow: save-to-file flow action row title
  ///
  /// In en, this message translates to:
  /// **'Save to file'**
  String get settingsFlowSaveToFile;

  /// Settings > Workflow: save-to-file flow action row hint
  ///
  /// In en, this message translates to:
  /// **'Write the image to the save folder'**
  String get settingsFlowSaveToFileHint;

  /// Settings > Workflow: copy-file-path flow action row title
  ///
  /// In en, this message translates to:
  /// **'Copy file path'**
  String get settingsFlowCopyFilePath;

  /// Settings > Workflow: copy-file-path flow action hint (save is enabled)
  ///
  /// In en, this message translates to:
  /// **'Put the saved file\'s path on the clipboard (instead of the image)'**
  String get settingsFlowCopyFilePathHint;

  /// Settings > Workflow: copy-file-path / show-in-finder hint when save is not enabled
  ///
  /// In en, this message translates to:
  /// **'Needs \"Save to file\"'**
  String get settingsFlowCopyFilePathNeedsSave;

  /// Settings > Workflow: show-in-Finder flow action row title
  ///
  /// In en, this message translates to:
  /// **'Show in Finder'**
  String get settingsFlowShowInFinder;

  /// Windows variant of settingsFlowShowInFinder (File Explorer)
  ///
  /// In en, this message translates to:
  /// **'Show in Explorer'**
  String get settingsFlowShowInFinderWin;

  /// Settings > Workflow: show-in-Finder flow action hint (save is enabled)
  ///
  /// In en, this message translates to:
  /// **'Reveal the saved file in Finder'**
  String get settingsFlowShowInFinderHint;

  /// Windows variant of settingsFlowShowInFinderHint
  ///
  /// In en, this message translates to:
  /// **'Reveal the saved file in Explorer'**
  String get settingsFlowShowInFinderHintWin;

  /// Settings > Workflow: open-in-editor flow action row title
  ///
  /// In en, this message translates to:
  /// **'Open in Image Editor'**
  String get settingsFlowOpenInEditor;

  /// Settings > Workflow: open-in-editor flow action row hint
  ///
  /// In en, this message translates to:
  /// **'Open the result in the Image Editor for further work'**
  String get settingsFlowOpenInEditorHint;

  /// Settings > Workflow: share-sheet flow action row title
  ///
  /// In en, this message translates to:
  /// **'Share sheet'**
  String get settingsFlowShareSheet;

  /// Settings > Workflow: share-sheet flow action row hint
  ///
  /// In en, this message translates to:
  /// **'Open the macOS share menu (AirDrop, Messages, …)'**
  String get settingsFlowShareSheetHint;

  /// Settings > Workflow: pin-to-screen flow action row title
  ///
  /// In en, this message translates to:
  /// **'Pin to screen'**
  String get settingsFlowPinToScreen;

  /// Settings > Workflow: pin-to-screen hint for the capture flow
  ///
  /// In en, this message translates to:
  /// **'Float the screenshot as an always-on-top window, pinned in place over where it was taken'**
  String get settingsFlowPinToScreenCaptureHint;

  /// Settings > Workflow: pin-to-screen hint for the editor flow
  ///
  /// In en, this message translates to:
  /// **'Float the result as an always-on-top window (centered)'**
  String get settingsFlowPinToScreenEditorHint;

  /// Settings > Workflow: caption below the After capture flow card (non-empty state)
  ///
  /// In en, this message translates to:
  /// **'Runs when a screenshot is confirmed: overlay ✓/Enter and the direct ⌘⌥2/3/4 modes.'**
  String get settingsFlowCaptureCaption;

  /// Settings > Workflow: caption below the After editor's Done flow card (non-empty state)
  ///
  /// In en, this message translates to:
  /// **'Runs when the Image Editor\'s Done button (or Enter) fires; the ▾ menu beside Done offers one-off alternatives.'**
  String get settingsFlowEditorCaption;

  /// Settings > Workflow: caption below the After capture flow card when no actions are selected
  ///
  /// In en, this message translates to:
  /// **'Runs when a screenshot is confirmed: overlay ✓/Enter and the direct ⌘⌥2/3/4 modes. Nothing is selected, so it falls back to Copy to clipboard.'**
  String get settingsFlowCaptureCaptionEmpty;

  /// Settings > Workflow: caption below the After editor's Done flow card when no actions are selected
  ///
  /// In en, this message translates to:
  /// **'Runs when the Image Editor\'s Done button (or Enter) fires; the ▾ menu beside Done offers one-off alternatives. Nothing is selected, so it falls back to Copy to clipboard.'**
  String get settingsFlowEditorCaptionEmpty;

  /// Settings > Workflow > Sounds: shutter sound toggle title
  ///
  /// In en, this message translates to:
  /// **'Shutter'**
  String get settingsSoundShutter;

  /// Settings > General > Sounds: shutter sound toggle hint
  ///
  /// In en, this message translates to:
  /// **'Plays when a capture completes'**
  String get settingsSoundShutterHint;

  /// Settings > Workflow > Sounds: completion sound toggle title
  ///
  /// In en, this message translates to:
  /// **'Completion'**
  String get settingsSoundCompletion;

  /// Settings > Workflow > Sounds: completion sound toggle hint
  ///
  /// In en, this message translates to:
  /// **'Chimes once the completion flow finishes'**
  String get settingsSoundCompletionHint;

  /// Settings > Output: Save location section label
  ///
  /// In en, this message translates to:
  /// **'Save location'**
  String get settingsSectionSaveLocation;

  /// Settings > Output: Format section label
  ///
  /// In en, this message translates to:
  /// **'Format'**
  String get settingsSectionFormat;

  /// Settings > Output: Filename section label
  ///
  /// In en, this message translates to:
  /// **'Filename'**
  String get settingsSectionFilename;

  /// Settings > Output: Decoration section label
  ///
  /// In en, this message translates to:
  /// **'Decoration'**
  String get settingsSectionDecoration;

  /// Settings > Output: Recent history section label
  ///
  /// In en, this message translates to:
  /// **'Recent history'**
  String get settingsSectionRecentHistory;

  /// Settings > Output > Save location: save folder card title
  ///
  /// In en, this message translates to:
  /// **'Save folder'**
  String get settingsSaveFolder;

  /// Settings > Output > Save location: choose directory button label
  ///
  /// In en, this message translates to:
  /// **'Choose…'**
  String get settingsSaveFolderChoose;

  /// Settings > Output > Save location: shown when no custom folder is set
  ///
  /// In en, this message translates to:
  /// **'Default · ~/Pictures/Glimpr'**
  String get settingsSaveFolderDefault;

  /// Settings > Output > Format: JPEG quality label
  ///
  /// In en, this message translates to:
  /// **'Quality'**
  String get settingsFormatQuality;

  /// Settings > Output > Format: JPEG quality hint
  ///
  /// In en, this message translates to:
  /// **'Compression level'**
  String get settingsFormatQualityHint;

  /// Settings > Output > Filename: preview label
  ///
  /// In en, this message translates to:
  /// **'Preview'**
  String get settingsFilenamePreview;

  /// No description provided for @settingsFilenameHint.
  ///
  /// In en, this message translates to:
  /// **'Uses the window under the cursor when the screenshot ends; %title and %app are left out on the bare desktop.'**
  String get settingsFilenameHint;

  /// No description provided for @settingsSectionSubfolder.
  ///
  /// In en, this message translates to:
  /// **'Subfolder'**
  String get settingsSectionSubfolder;

  /// No description provided for @settingsInsertVariable.
  ///
  /// In en, this message translates to:
  /// **'Insert variable'**
  String get settingsInsertVariable;

  /// No description provided for @settingsPatternNormalizeHint.
  ///
  /// In en, this message translates to:
  /// **'Reserved characters will be removed on Apply.'**
  String get settingsPatternNormalizeHint;

  /// No description provided for @settingsPreviewCollision.
  ///
  /// In en, this message translates to:
  /// **'If the name is taken'**
  String get settingsPreviewCollision;

  /// No description provided for @settingsPreviewModeWindow.
  ///
  /// In en, this message translates to:
  /// **'Window'**
  String get settingsPreviewModeWindow;

  /// No description provided for @settingsPreviewModeDisplay.
  ///
  /// In en, this message translates to:
  /// **'Full screen'**
  String get settingsPreviewModeDisplay;

  /// No description provided for @settingsPreviewModeLast.
  ///
  /// In en, this message translates to:
  /// **'Last region'**
  String get settingsPreviewModeLast;

  /// No description provided for @settingsPreviewModeRecording.
  ///
  /// In en, this message translates to:
  /// **'Recording'**
  String get settingsPreviewModeRecording;

  /// No description provided for @settingsPreviewModeDesktop.
  ///
  /// In en, this message translates to:
  /// **'No window'**
  String get settingsPreviewModeDesktop;

  /// No description provided for @settingsSubfolderHint.
  ///
  /// In en, this message translates to:
  /// **'Leave empty to save directly in the folder above. Use / for nested folders.'**
  String get settingsSubfolderHint;

  /// No description provided for @tokCatDateTime.
  ///
  /// In en, this message translates to:
  /// **'Date & time'**
  String get tokCatDateTime;

  /// No description provided for @tokCatContent.
  ///
  /// In en, this message translates to:
  /// **'Content'**
  String get tokCatContent;

  /// No description provided for @tokCatCounter.
  ///
  /// In en, this message translates to:
  /// **'Counter'**
  String get tokCatCounter;

  /// No description provided for @tokCatRandom.
  ///
  /// In en, this message translates to:
  /// **'Random'**
  String get tokCatRandom;

  /// No description provided for @tokCatComputer.
  ///
  /// In en, this message translates to:
  /// **'Computer'**
  String get tokCatComputer;

  /// No description provided for @tokYear4.
  ///
  /// In en, this message translates to:
  /// **'4-digit year'**
  String get tokYear4;

  /// No description provided for @tokYear2.
  ///
  /// In en, this message translates to:
  /// **'2-digit year'**
  String get tokYear2;

  /// No description provided for @tokMonth.
  ///
  /// In en, this message translates to:
  /// **'Month, 01 to 12'**
  String get tokMonth;

  /// No description provided for @tokDay.
  ///
  /// In en, this message translates to:
  /// **'Day of month, 01 to 31'**
  String get tokDay;

  /// No description provided for @tokHour24.
  ///
  /// In en, this message translates to:
  /// **'Hour, 24-hour (00 to 23)'**
  String get tokHour24;

  /// No description provided for @tokHour12.
  ///
  /// In en, this message translates to:
  /// **'Hour, 12-hour (01 to 12)'**
  String get tokHour12;

  /// No description provided for @tokMinute.
  ///
  /// In en, this message translates to:
  /// **'Minute, 00 to 59'**
  String get tokMinute;

  /// No description provided for @tokSecond.
  ///
  /// In en, this message translates to:
  /// **'Second, 00 to 59'**
  String get tokSecond;

  /// No description provided for @tokAmPm.
  ///
  /// In en, this message translates to:
  /// **'AM or PM'**
  String get tokAmPm;

  /// No description provided for @tokDayOfYear.
  ///
  /// In en, this message translates to:
  /// **'Day of the year, 001 to 366'**
  String get tokDayOfYear;

  /// No description provided for @tokWeek.
  ///
  /// In en, this message translates to:
  /// **'ISO week number, 01 to 53'**
  String get tokWeek;

  /// No description provided for @tokWeekdayShort.
  ///
  /// In en, this message translates to:
  /// **'Weekday, short (Mon)'**
  String get tokWeekdayShort;

  /// No description provided for @tokWeekdayFull.
  ///
  /// In en, this message translates to:
  /// **'Weekday, full (Monday)'**
  String get tokWeekdayFull;

  /// No description provided for @tokMonthShort.
  ///
  /// In en, this message translates to:
  /// **'Month name, short (Jun)'**
  String get tokMonthShort;

  /// No description provided for @tokMonthFull.
  ///
  /// In en, this message translates to:
  /// **'Month name, full (June)'**
  String get tokMonthFull;

  /// No description provided for @tokUnix.
  ///
  /// In en, this message translates to:
  /// **'Unix timestamp (seconds)'**
  String get tokUnix;

  /// No description provided for @tokTitle.
  ///
  /// In en, this message translates to:
  /// **'Window title, or the app name if it has none'**
  String get tokTitle;

  /// No description provided for @tokApp.
  ///
  /// In en, this message translates to:
  /// **'Application name'**
  String get tokApp;

  /// No description provided for @tokCounter.
  ///
  /// In en, this message translates to:
  /// **'Auto-increment counter; %iN pads to N digits'**
  String get tokCounter;

  /// No description provided for @tokRandAlnum.
  ///
  /// In en, this message translates to:
  /// **'Random letters & digits; %raN sets the length'**
  String get tokRandAlnum;

  /// No description provided for @tokRandNum.
  ///
  /// In en, this message translates to:
  /// **'Random digits; %rnN sets the length'**
  String get tokRandNum;

  /// No description provided for @tokRandHex.
  ///
  /// In en, this message translates to:
  /// **'Random hexadecimal; %rxN sets the length'**
  String get tokRandHex;

  /// No description provided for @tokGuid.
  ///
  /// In en, this message translates to:
  /// **'Random GUID'**
  String get tokGuid;

  /// No description provided for @tokHost.
  ///
  /// In en, this message translates to:
  /// **'Computer name'**
  String get tokHost;

  /// No description provided for @tokUser.
  ///
  /// In en, this message translates to:
  /// **'User name'**
  String get tokUser;

  /// Settings > Screenshot > Decoration: interactive-overlay snap toggle title (snaps to a window or AX element)
  ///
  /// In en, this message translates to:
  /// **'Snap'**
  String get settingsDecorationSnap;

  /// Settings > Screenshot > Decoration: interactive-overlay snap toggle hint
  ///
  /// In en, this message translates to:
  /// **'Shadow + margin on a snapped screenshot'**
  String get settingsDecorationSnapHint;

  /// Settings > Output > Decoration: freehand crop toggle title
  ///
  /// In en, this message translates to:
  /// **'Freehand crop'**
  String get settingsDecorationFreehandCrop;

  /// Settings > Output > Decoration: freehand crop toggle hint
  ///
  /// In en, this message translates to:
  /// **'Shadow + margin on a dragged crop region'**
  String get settingsDecorationFreehandCropHint;

  /// Settings > Output > Decoration: focused window toggle title
  ///
  /// In en, this message translates to:
  /// **'Focused window'**
  String get settingsDecorationFocusedWindow;

  /// Settings > Output > Decoration: focused window toggle hint
  ///
  /// In en, this message translates to:
  /// **'Screenshot-window mode (⌘⌥2)'**
  String get settingsDecorationFocusedWindowHint;

  /// Settings > Output > Decoration: display toggle title
  ///
  /// In en, this message translates to:
  /// **'Display'**
  String get settingsDecorationDisplay;

  /// Settings > Output > Decoration: display toggle hint
  ///
  /// In en, this message translates to:
  /// **'Screenshot-display mode (⌘⌥3)'**
  String get settingsDecorationDisplayHint;

  /// Settings > Output > Decoration: last region toggle title
  ///
  /// In en, this message translates to:
  /// **'Last region'**
  String get settingsDecorationLastRegion;

  /// Settings > Output > Decoration: last region toggle hint
  ///
  /// In en, this message translates to:
  /// **'Screenshot-last-region mode (⌘⌥4)'**
  String get settingsDecorationLastRegionHint;

  /// Settings > Output > Decoration: JPEG fill swatch row title
  ///
  /// In en, this message translates to:
  /// **'JPEG background fill'**
  String get settingsDecorationJpegFill;

  /// Settings > Output > Decoration: JPEG fill swatch row hint
  ///
  /// In en, this message translates to:
  /// **'Colour behind the margin when saving as JPEG'**
  String get settingsDecorationJpegFillHint;

  /// Settings > Output > Decoration: footnote that pin ignores decoration
  ///
  /// In en, this message translates to:
  /// **'Decoration applies to the exported image (file, clipboard, share, editor). Pinned images always use the undecorated original.'**
  String get settingsDecorationPinNote;

  /// Settings > Screenshot: pinned-window section label
  ///
  /// In en, this message translates to:
  /// **'Pin'**
  String get settingsSectionPin;

  /// Settings > Screenshot > Pin: toggle title for the pinned-window hover halo
  ///
  /// In en, this message translates to:
  /// **'Hover glow'**
  String get settingsPinHoverGlow;

  /// Settings > Screenshot > Pin: hover-glow toggle hint
  ///
  /// In en, this message translates to:
  /// **'Show the glowing halo around a pinned window on hover; the controls still appear when off'**
  String get settingsPinHoverGlowHint;

  /// Settings > Capture: screen recording section label
  ///
  /// In en, this message translates to:
  /// **'Screen recording'**
  String get settingsSectionRecording;

  /// Settings > Capture > Screen recording: shown on macOS 14
  ///
  /// In en, this message translates to:
  /// **'Screen recording needs macOS 15 or later.'**
  String get settingsRecordingUnavailable;

  /// Settings > Capture > Screen recording: fps row title
  ///
  /// In en, this message translates to:
  /// **'Frame rate'**
  String get settingsRecordingFps;

  /// Settings > Capture > Screen recording: fps row hint (video formats)
  ///
  /// In en, this message translates to:
  /// **'60 fps is smoother but roughly doubles the file size'**
  String get settingsRecordingFpsHint;

  /// Settings > Recording: mp4 video quality row title
  ///
  /// In en, this message translates to:
  /// **'Video quality'**
  String get settingsRecordingQuality;

  /// Settings > Recording: video quality row hint (video formats)
  ///
  /// In en, this message translates to:
  /// **'Higher quality looks crisper but makes larger files; applies to mp4 (H.264 / HEVC)'**
  String get settingsRecordingQualityHint;

  /// Settings > Recording: video quality tier (low)
  ///
  /// In en, this message translates to:
  /// **'Low'**
  String get settingsRecordingQualityLow;

  /// Settings > Recording: video quality tier (medium)
  ///
  /// In en, this message translates to:
  /// **'Medium'**
  String get settingsRecordingQualityMedium;

  /// Settings > Recording: video quality tier (high)
  ///
  /// In en, this message translates to:
  /// **'High'**
  String get settingsRecordingQualityHigh;

  /// Settings > Recording: output resolution cap row title (shared by video and GIF)
  ///
  /// In en, this message translates to:
  /// **'Resolution limit'**
  String get settingsRecordingResolution;

  /// Settings > Recording: resolution cap row hint
  ///
  /// In en, this message translates to:
  /// **'Cap the longest side in pixels; larger recordings are downscaled. Video only (GIF is fixed at 1024 px)'**
  String get settingsRecordingResolutionHint;

  /// Settings > Recording: resolution cap option meaning no downscale (native resolution)
  ///
  /// In en, this message translates to:
  /// **'Native'**
  String get settingsRecordingResolutionNative;

  /// Settings > Recording: GIF frame-rate row hint (GIF section)
  ///
  /// In en, this message translates to:
  /// **'Frames per second for GIF recordings; higher is smoother but larger'**
  String get settingsRecordingGifFpsHint;

  /// Settings > Recording: caution shown under the Format card when GIF is selected; GIF buffers all frames in memory until finalize, so long recordings risk running out of memory
  ///
  /// In en, this message translates to:
  /// **'GIF holds every frame in memory until it finishes, so a long GIF recording can use several gigabytes and may run out of memory. Keep GIF recordings short.'**
  String get settingsRecordingGifLengthCaution;

  /// Settings > Capture > Screen recording: output format row title
  ///
  /// In en, this message translates to:
  /// **'Format'**
  String get settingsRecordingFormat;

  /// Settings > Capture > Screen recording: format row hint
  ///
  /// In en, this message translates to:
  /// **'H.264 and HEVC are mp4 video; GIF is a silent animated image'**
  String get settingsRecordingFormatHint;

  /// Settings > Capture > Screen recording: countdown row title
  ///
  /// In en, this message translates to:
  /// **'Countdown'**
  String get settingsRecordingCountdown;

  /// Settings > Capture > Screen recording: countdown row hint
  ///
  /// In en, this message translates to:
  /// **'Wait before recording starts; any recording hotkey cancels the countdown'**
  String get settingsRecordingCountdownHint;

  /// Settings > Capture > Screen recording: fixed-duration row title
  ///
  /// In en, this message translates to:
  /// **'Stop after'**
  String get settingsRecordingMaxDuration;

  /// Settings > Capture > Screen recording: fixed-duration row hint
  ///
  /// In en, this message translates to:
  /// **'Automatically stop the recording after this long'**
  String get settingsRecordingMaxDurationHint;

  /// Screen recording: countdown / stop-after option meaning disabled
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get settingsRecordingDurationOff;

  /// Screen recording: compact seconds unit suffix (e.g. 5s)
  ///
  /// In en, this message translates to:
  /// **'s'**
  String get settingsRecordingSecondsSuffix;

  /// Settings > Capture > Screen recording: cursor row hint
  ///
  /// In en, this message translates to:
  /// **'Include the mouse pointer in the recording'**
  String get settingsRecordingCursorHint;

  /// Settings > Capture > Screen recording: system audio row title
  ///
  /// In en, this message translates to:
  /// **'Record system audio'**
  String get settingsRecordingSystemAudio;

  /// Settings > Capture > Screen recording: system audio row hint
  ///
  /// In en, this message translates to:
  /// **'Include the sound the system is playing'**
  String get settingsRecordingSystemAudioHint;

  /// Settings > Capture > Screen recording: microphone row title
  ///
  /// In en, this message translates to:
  /// **'Record microphone'**
  String get settingsRecordingMicrophone;

  /// Settings > Capture > Screen recording: microphone row hint
  ///
  /// In en, this message translates to:
  /// **'Asks for microphone permission on first use'**
  String get settingsRecordingMicrophoneHint;

  /// Settings > Capture > Screen recording: merge-audio row title
  ///
  /// In en, this message translates to:
  /// **'Merge audio into one track'**
  String get settingsRecordingMergeAudio;

  /// Settings > Capture > Screen recording: merge-audio row hint
  ///
  /// In en, this message translates to:
  /// **'Combine system audio and microphone into a single track for wider compatibility; applies only when both are recorded'**
  String get settingsRecordingMergeAudioHint;

  /// Settings > Recording: toggle for dimming the area outside the recorded region (and other displays)
  ///
  /// In en, this message translates to:
  /// **'Dim outside the recording'**
  String get settingsRecordingDim;

  /// Settings > Recording: hint for the recording dim toggle
  ///
  /// In en, this message translates to:
  /// **'Darkens the area outside the region and other displays. Turn off for a clear screen during long recordings; the red frame stays.'**
  String get settingsRecordingDimHint;

  /// Settings > Capture: after-recording flow section label
  ///
  /// In en, this message translates to:
  /// **'After recording'**
  String get settingsSectionAfterRecording;

  /// Settings > Output > Recent history: card title
  ///
  /// In en, this message translates to:
  /// **'Recent images kept'**
  String get settingsRecentImagesKept;

  /// Settings > Output > Recent history: card hint
  ///
  /// In en, this message translates to:
  /// **'How many images the landing gallery and the menu-bar Open Recent keep.'**
  String get settingsRecentImagesKeptHint;

  /// Settings > Advanced: Multi-display section label
  ///
  /// In en, this message translates to:
  /// **'Multi-display'**
  String get settingsSectionMultiDisplay;

  /// Settings > Advanced > Multi-display: warm engines card title
  ///
  /// In en, this message translates to:
  /// **'Warm screenshot engines'**
  String get settingsWarmEnginesTitle;

  /// Settings > Advanced > Multi-display: warm engines explanatory body (multi-paragraph)
  ///
  /// In en, this message translates to:
  /// **'How many displays Glimpr keeps instantly screenshot-ready, including displays connected after the app has launched (e.g. plugging into a dock). Glimpr pre-warms a rendering engine per display so the freeze overlay appears with no delay.\n\nThis is a minimum, not a cap: every display already connected when Glimpr starts gets a warm engine regardless of this number; it only adds spares for displays plugged in later.\n\nCost: each engine uses about 10 MB of memory while Glimpr runs. A display plugged in beyond this number still screenshots, but only shows the frozen frame; its crosshair and toolbar follow correctly after a restart (which makes every connected display warm again).'**
  String get settingsWarmEnginesBody;

  /// Settings > Advanced > Multi-display: caption shown when warm target equals the initial value
  ///
  /// In en, this message translates to:
  /// **'Default 2 · applies after restarting Glimpr'**
  String get settingsWarmEnginesDefault;

  /// Settings > Advanced: Capture layers section label
  ///
  /// In en, this message translates to:
  /// **'Screenshot layers'**
  String get settingsSectionCaptureLayers;

  /// Settings > Advanced > Capture layers: card title
  ///
  /// In en, this message translates to:
  /// **'Screenshot layers'**
  String get settingsCaptureLayersTitle;

  /// Settings > Advanced > Capture layers: explanatory body (multi-paragraph)
  ///
  /// In en, this message translates to:
  /// **'Press the screenshot shortcut while a screenshot is already open to stack a new freeze on top (the previous layer stays in the screenshot, annotations and all); finishing or cancelling a layer returns to the one below.\n\nWith 1 (the default) nothing stacks: a new trigger restarts the screenshot. With 2 to 5, the OLDEST layer is dropped once the cap is reached, keeping the most recent ones; the toolbar announces both cases.\n\nCost: each stacked layer holds a full-resolution frozen image per display (roughly 30 to 60 MB at 4K or 5K) while the session is open. Applies on the next screenshot; no restart needed.'**
  String get settingsCaptureLayersBody;

  /// Settings > Advanced: Element snap section label
  ///
  /// In en, this message translates to:
  /// **'Element snap'**
  String get settingsSectionElementSnap;

  /// Settings > Advanced > Element snap: toggle title
  ///
  /// In en, this message translates to:
  /// **'Precise element snap (experimental)'**
  String get settingsElementSnapTitle;

  /// Settings > Advanced > Element snap: explanatory body
  ///
  /// In en, this message translates to:
  /// **'Snap to the UI element under the cursor (a button, a pane, a list row) instead of the whole window. Works for both screenshots and recording region select; use the scroll wheel to grow or shrink the selection along the element tree.\n\nNeeds Accessibility permission, which lets Glimpr read the on-screen UI of other apps system-wide (not only while capturing). Each hover runs a live query (typically a few milliseconds, a little more on a busy app) versus none for plain window snap; it runs off the render thread, so it never stalls the overlay. How finely an app can be snapped is up to that app: native apps expose detailed elements, while some browsers, Electron, custom-drawn or game interfaces expose little and fall back to window snap. The captured region is the element\'s reported bounds, so it can include the element\'s own padding. Experimental: the highlight is queried live, so it may briefly differ from the frozen screenshot if a window moves underneath.'**
  String get settingsElementSnapBody;

  /// Settings > Advanced > Element snap: permission-missing notice
  ///
  /// In en, this message translates to:
  /// **'Accessibility permission not granted'**
  String get settingsElementSnapNeedsPermission;

  /// Settings > Advanced > Element snap: button that opens the Accessibility permission prompt
  ///
  /// In en, this message translates to:
  /// **'Grant…'**
  String get settingsElementSnapGrant;

  /// Capture loupe element-snap level block: the current level
  ///
  /// In en, this message translates to:
  /// **'Element level {lvl}'**
  String elementSnapLevelLabel(String lvl);

  /// Loupe shortcuts block: the keys that change the element level
  ///
  /// In en, this message translates to:
  /// **'Scroll or , .'**
  String get loupeShortcutWalkKey;

  /// Loupe shortcuts block: what the element-level keys do
  ///
  /// In en, this message translates to:
  /// **'element level'**
  String get loupeShortcutWalkDesc;

  /// Loupe shortcuts block: the keys that nudge the cursor
  ///
  /// In en, this message translates to:
  /// **'Arrow keys'**
  String get loupeShortcutNudgeKey;

  /// Loupe shortcuts block: what the arrow keys do
  ///
  /// In en, this message translates to:
  /// **'nudge'**
  String get loupeShortcutNudgeDesc;

  /// Loupe shortcuts block: the Shift key whose drag constraint depends on the tool
  ///
  /// In en, this message translates to:
  /// **'Shift'**
  String get loupeShortcutAngleKey;

  /// Loupe shortcuts block: Shift squares a box/region drag
  ///
  /// In en, this message translates to:
  /// **'square'**
  String get loupeShortcutSquareDesc;

  /// Loupe shortcuts block: Shift makes the ellipse a circle
  ///
  /// In en, this message translates to:
  /// **'circle'**
  String get loupeShortcutCircleDesc;

  /// Loupe shortcuts block: Shift snaps a line/arrow drag to 45 degrees
  ///
  /// In en, this message translates to:
  /// **'45°'**
  String get loupeShortcut45Desc;

  /// Loupe shortcuts block: copy the sampled colour as HEX (eyedropper)
  ///
  /// In en, this message translates to:
  /// **'copy HEX'**
  String get loupeShortcutCopyHexDesc;

  /// Loupe shortcuts block: copy the sampled colour as RGB (eyedropper)
  ///
  /// In en, this message translates to:
  /// **'copy RGB'**
  String get loupeShortcutCopyRgbDesc;

  /// Loupe shortcuts block: copy the sampled colour as HSL (eyedropper)
  ///
  /// In en, this message translates to:
  /// **'copy HSL'**
  String get loupeShortcutCopyHslDesc;

  /// Settings > Shortcuts: the fixed key that cycles the loupe info display
  ///
  /// In en, this message translates to:
  /// **'Cycle loupe info'**
  String get settingsCycleLoupeInfo;

  /// Settings > Shortcuts > Reserved: cycle-loupe-info row hint
  ///
  /// In en, this message translates to:
  /// **'Cycle what the loupe shows: coordinates, element level, shortcuts, hidden.'**
  String get settingsCycleLoupeInfoHint;

  /// Settings > Shortcuts > Reserved: element-snap level keys row title
  ///
  /// In en, this message translates to:
  /// **'Element snap level'**
  String get settingsReservedElementSnapLevel;

  /// Settings > Shortcuts > Reserved: element-snap level keys row hint
  ///
  /// In en, this message translates to:
  /// **'While precise element snap is on, , and . (or the scroll wheel) shrink and grow the snapped element along its tree.'**
  String get settingsReservedElementSnapLevelHint;

  /// Element snap level label at the auto-picked element
  ///
  /// In en, this message translates to:
  /// **'auto'**
  String get elementSnapLevelDefault;

  /// Element snap level label, n levels toward the ancestor (bigger)
  ///
  /// In en, this message translates to:
  /// **'out {n}'**
  String elementSnapLevelOut(int n);

  /// Element snap level label, n levels toward the leaf (smaller)
  ///
  /// In en, this message translates to:
  /// **'in {n}'**
  String elementSnapLevelIn(int n);

  /// Settings > Advanced: Tool styles section label
  ///
  /// In en, this message translates to:
  /// **'Tool styles'**
  String get settingsSectionToolStyles;

  /// Settings > Advanced > Tool styles: reset button label and card title
  ///
  /// In en, this message translates to:
  /// **'Reset all tool styles'**
  String get settingsResetAllToolStyles;

  /// Settings > Advanced > Tool styles: card hint text
  ///
  /// In en, this message translates to:
  /// **'Restore every annotation tool (colour, stroke, font size, font) to its default. Takes effect on your next screenshot.'**
  String get settingsResetAllToolStylesHint;

  /// Settings > Advanced > Tool styles: confirm label for the two-step reset button
  ///
  /// In en, this message translates to:
  /// **'Click again to reset all tool styles'**
  String get settingsResetAllToolStylesConfirm;

  /// Settings > Shortcuts: Capture section note
  ///
  /// In en, this message translates to:
  /// **'Fire globally, from any app'**
  String get settingsShortcutsCaptureNote;

  /// Settings > Shortcuts: Recording section note on recording-vs-screenshot hotkey behaviour
  ///
  /// In en, this message translates to:
  /// **'While recording, any recording hotkey stops it (not cancel); screenshot hotkeys still work, so you can capture a still while recording'**
  String get settingsShortcutsRecordingNote;

  /// Settings > Shortcuts > Commands: Undo row title
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get settingsCmdUndo;

  /// Settings > Shortcuts > Commands: Redo row title
  ///
  /// In en, this message translates to:
  /// **'Redo'**
  String get settingsCmdRedo;

  /// Settings > Shortcuts > Commands: Paste image row title
  ///
  /// In en, this message translates to:
  /// **'Paste image'**
  String get settingsCmdPasteImage;

  /// Settings > Shortcuts > Commands: Paste image row hint
  ///
  /// In en, this message translates to:
  /// **'From the clipboard'**
  String get settingsCmdPasteImageHint;

  /// Settings > Shortcuts > Commands: Delete selected row title
  ///
  /// In en, this message translates to:
  /// **'Delete selected'**
  String get settingsCmdDeleteSelected;

  /// Settings > Shortcuts > Commands: Delete selected row hint
  ///
  /// In en, this message translates to:
  /// **'Remove the selected annotation'**
  String get settingsCmdDeleteSelectedHint;

  /// Settings > Shortcuts > Commands: Export row title
  ///
  /// In en, this message translates to:
  /// **'Export'**
  String get settingsCmdExport;

  /// Settings > Shortcuts > Commands: Export row hint
  ///
  /// In en, this message translates to:
  /// **'Screenshot the snapped window, or the whole screen'**
  String get settingsCmdExportHint;

  /// Settings > Shortcuts > Commands: Duplicate selected row title
  ///
  /// In en, this message translates to:
  /// **'Duplicate selected'**
  String get settingsCmdDuplicateSelected;

  /// Settings > Shortcuts > Commands: Duplicate selected row hint
  ///
  /// In en, this message translates to:
  /// **'Copy the selected annotation'**
  String get settingsCmdDuplicateSelectedHint;

  /// Settings > Shortcuts > Commands: Bring to front row title
  ///
  /// In en, this message translates to:
  /// **'Bring to front'**
  String get settingsCmdBringToFront;

  /// Settings > Shortcuts > Commands: Bring to front row hint
  ///
  /// In en, this message translates to:
  /// **'Move the selection above others'**
  String get settingsCmdBringToFrontHint;

  /// Settings > Shortcuts > Commands: Send to back row title
  ///
  /// In en, this message translates to:
  /// **'Send to back'**
  String get settingsCmdSendToBack;

  /// Settings > Shortcuts > Commands: Send to back row hint
  ///
  /// In en, this message translates to:
  /// **'Move the selection below others'**
  String get settingsCmdSendToBackHint;

  /// Settings > Shortcuts > Commands: Copy color as HEX row title
  ///
  /// In en, this message translates to:
  /// **'Copy color as HEX'**
  String get settingsCmdCopyHex;

  /// Settings > Shortcuts > Commands: hint for copy-color-as-* rows
  ///
  /// In en, this message translates to:
  /// **'While the color picker is sampling'**
  String get settingsCmdCopyColorHint;

  /// Settings > Shortcuts > Commands: Copy color as RGB row title
  ///
  /// In en, this message translates to:
  /// **'Copy color as RGB'**
  String get settingsCmdCopyRgb;

  /// Settings > Shortcuts > Commands: Copy color as HSL row title
  ///
  /// In en, this message translates to:
  /// **'Copy color as HSL'**
  String get settingsCmdCopyHsl;

  /// Settings > Shortcuts > Commands: toggle crosshair lines row title
  ///
  /// In en, this message translates to:
  /// **'Toggle crosshair'**
  String get settingsCmdToggleCrosshair;

  /// Settings > Shortcuts > Commands: toggle crosshair row hint
  ///
  /// In en, this message translates to:
  /// **'Show or hide the crosshair lines for the current session'**
  String get settingsCmdToggleCrosshairHint;

  /// Settings > Shortcuts > Commands: toggle pixel loupe row title
  ///
  /// In en, this message translates to:
  /// **'Toggle loupe'**
  String get settingsCmdToggleLoupe;

  /// Settings > Shortcuts > Commands: toggle loupe row hint
  ///
  /// In en, this message translates to:
  /// **'Show or hide the pixel loupe for the current session'**
  String get settingsCmdToggleLoupeHint;

  /// Settings > Shortcuts > Reserved: Cancel/Exit row title
  ///
  /// In en, this message translates to:
  /// **'Cancel / Exit'**
  String get settingsReservedCancelExit;

  /// Settings > Shortcuts > Reserved: generic reserved hint
  ///
  /// In en, this message translates to:
  /// **'Reserved'**
  String get settingsReservedHint;

  /// Settings > Shortcuts > Reserved: Close window row title
  ///
  /// In en, this message translates to:
  /// **'Close window'**
  String get settingsReservedCloseWindow;

  /// Settings > Shortcuts > Reserved: hint for keys reserved in editor/settings
  ///
  /// In en, this message translates to:
  /// **'Reserved · editor / settings'**
  String get settingsReservedHintEditorSettings;

  /// Settings > Shortcuts > Reserved: Open Settings row title
  ///
  /// In en, this message translates to:
  /// **'Open Settings'**
  String get settingsReservedOpenSettings;

  /// Settings > Shortcuts > Reserved: hint for keys reserved in overlay/editor
  ///
  /// In en, this message translates to:
  /// **'Reserved · overlay / editor'**
  String get settingsReservedHintOverlayEditor;

  /// Settings > Shortcuts > Reserved: Nudge crosshair row title
  ///
  /// In en, this message translates to:
  /// **'Nudge crosshair'**
  String get settingsReservedNudgeCrosshair;

  /// Settings > Shortcuts > Reserved: hint for keys reserved in region tools
  ///
  /// In en, this message translates to:
  /// **'Reserved · region tools'**
  String get settingsReservedHintRegionTools;

  /// Settings > Shortcuts > Reserved: Fit to window row title
  ///
  /// In en, this message translates to:
  /// **'Fit to window'**
  String get settingsReservedFitToWindow;

  /// Settings > Shortcuts > Reserved: hint for keys reserved in image editor
  ///
  /// In en, this message translates to:
  /// **'Reserved · image editor'**
  String get settingsReservedHintImageEditor;

  /// Settings > Shortcuts > Reserved: Zoom to 100% row title
  ///
  /// In en, this message translates to:
  /// **'Zoom to 100%'**
  String get settingsReservedZoomTo100;

  /// Settings > Shortcuts > Reserved: Commit text row title
  ///
  /// In en, this message translates to:
  /// **'Commit text'**
  String get settingsReservedCommitText;

  /// Settings > Shortcuts > Reserved: hint for keys reserved while editing text
  ///
  /// In en, this message translates to:
  /// **'Reserved · while editing text'**
  String get settingsReservedHintWhileEditingText;

  /// Settings > Shortcuts > Reserved: New line row title
  ///
  /// In en, this message translates to:
  /// **'New line'**
  String get settingsReservedNewLine;

  /// Settings > Shortcuts > Reserved: Cancel text row title
  ///
  /// In en, this message translates to:
  /// **'Cancel text'**
  String get settingsReservedCancelText;

  /// Settings > Shortcuts: warning shown when two shortcuts share the same key combo
  ///
  /// In en, this message translates to:
  /// **'Duplicate'**
  String get settingsShortcutsDuplicate;

  /// Settings > Shortcuts: inline warning when a global shortcut could not be registered because the combo is reserved by the system or already taken by another app
  ///
  /// In en, this message translates to:
  /// **'In use by another app'**
  String get settingsShortcutsInUse;

  /// Startup warning dialog shown when one or more saved global hotkeys failed to register at launch (conflict with another app); the conflicting shortcuts are listed after this line
  ///
  /// In en, this message translates to:
  /// **'Some shortcuts couldn\'t be registered: they\'re in use by another app and won\'t work. Please check them in Settings → Shortcuts:'**
  String get shortcutsConflictWarning;

  /// Native error alert: a direct capture produced no image
  ///
  /// In en, this message translates to:
  /// **'Capture failed'**
  String get errorCaptureFailed;

  /// Native error alert: a direct capture threw; detail is the raw error
  ///
  /// In en, this message translates to:
  /// **'Capture failed: {detail}'**
  String errorCaptureFailedDetail(String detail);

  /// Native error alert: starting/finishing a recording failed; detail is the raw error
  ///
  /// In en, this message translates to:
  /// **'Recording failed: {detail}'**
  String errorRecordingFailedDetail(String detail);

  /// Native error alert: record-window found no eligible window
  ///
  /// In en, this message translates to:
  /// **'No window to record'**
  String get errorNoWindowToRecord;

  /// Native error alert: the pin-clipboard / open-clipboard action found no image on the clipboard
  ///
  /// In en, this message translates to:
  /// **'No image in clipboard'**
  String get errorNoImageInClipboard;

  /// Settings > Shortcuts: tooltip on the per-shortcut reset icon button
  ///
  /// In en, this message translates to:
  /// **'Reset to default'**
  String get settingsShortcutsResetToDefault;

  /// Settings > Shortcuts: Revert button in the footer bar
  ///
  /// In en, this message translates to:
  /// **'Revert'**
  String get settingsShortcutsRevert;

  /// Settings > Shortcuts: Apply button in the footer bar
  ///
  /// In en, this message translates to:
  /// **'Apply'**
  String get settingsShortcutsApply;

  /// Settings > Shortcuts: Tools section label
  ///
  /// In en, this message translates to:
  /// **'Tools'**
  String get settingsShortcutsTools;

  /// Settings > Shortcuts: Commands section label
  ///
  /// In en, this message translates to:
  /// **'Commands'**
  String get settingsShortcutsCommands;

  /// Settings > Shortcuts: Reserved section label
  ///
  /// In en, this message translates to:
  /// **'Reserved'**
  String get settingsShortcutsReserved;

  /// Settings > Shortcuts: scope tag for system-wide hotkeys
  ///
  /// In en, this message translates to:
  /// **'Global'**
  String get scopeGlobal;

  /// Settings > Shortcuts: scope tag for editor (overlay + image editor) shortcuts
  ///
  /// In en, this message translates to:
  /// **'Editor'**
  String get scopeEditor;

  /// Settings > Shortcuts: scope tag for capture-overlay-only shortcuts
  ///
  /// In en, this message translates to:
  /// **'Overlay'**
  String get scopeOverlay;

  /// Settings > Shortcuts: scope tag for image-editor-only shortcuts
  ///
  /// In en, this message translates to:
  /// **'Image'**
  String get scopeImage;

  /// Settings > Shortcuts: scope tag for shortcuts active only while editing a text annotation
  ///
  /// In en, this message translates to:
  /// **'Text'**
  String get scopeText;

  /// Settings > Shortcuts legend: gloss for the Global scope tag
  ///
  /// In en, this message translates to:
  /// **'System-wide hotkeys'**
  String get scopeGlobalDesc;

  /// Settings > Shortcuts legend: gloss for the Editor scope tag
  ///
  /// In en, this message translates to:
  /// **'Capture overlay and image editor'**
  String get scopeEditorDesc;

  /// Settings > Shortcuts legend: gloss for the Overlay scope tag
  ///
  /// In en, this message translates to:
  /// **'Capture overlay only'**
  String get scopeOverlayDesc;

  /// Settings > Shortcuts legend: gloss for the Image scope tag
  ///
  /// In en, this message translates to:
  /// **'Image editor only'**
  String get scopeImageDesc;

  /// Settings > Shortcuts legend: gloss for the Text scope tag
  ///
  /// In en, this message translates to:
  /// **'While editing a text annotation'**
  String get scopeTextDesc;

  /// Settings > Shortcuts: legend intro explaining page-wide uniqueness and the scope tags
  ///
  /// In en, this message translates to:
  /// **'Every shortcut must be unique across the whole page, so a key combination can\'t be used twice and reserved keys can\'t be reassigned. The tag on each row shows where it applies:'**
  String get shortcutsLegendDedup;

  /// Global action label: interactive capture
  ///
  /// In en, this message translates to:
  /// **'Screenshot Region'**
  String get actionCapture;

  /// Global action hint: interactive capture
  ///
  /// In en, this message translates to:
  /// **'Select a region and screenshot it; press again to stack'**
  String get actionCaptureHint;

  /// Global action label: capture window
  ///
  /// In en, this message translates to:
  /// **'Screenshot Window'**
  String get actionCaptureWindow;

  /// Global action hint: capture window
  ///
  /// In en, this message translates to:
  /// **'Screenshot the focused window'**
  String get actionCaptureWindowHint;

  /// Global action label: capture display
  ///
  /// In en, this message translates to:
  /// **'Screenshot Display'**
  String get actionCaptureDisplay;

  /// Global action hint: capture display
  ///
  /// In en, this message translates to:
  /// **'Screenshot the display under the cursor'**
  String get actionCaptureDisplayHint;

  /// Global action label: capture last region
  ///
  /// In en, this message translates to:
  /// **'Screenshot Last Region'**
  String get actionCaptureLastRegion;

  /// Global action hint: capture last region
  ///
  /// In en, this message translates to:
  /// **'Repeat the last screenshot region'**
  String get actionCaptureLastRegionHint;

  /// Global action label: open editor
  ///
  /// In en, this message translates to:
  /// **'Open Image Editor'**
  String get actionOpenEditor;

  /// Global action hint: open editor
  ///
  /// In en, this message translates to:
  /// **'Open the Image Editor'**
  String get actionOpenEditorHint;

  /// Global action label: open editor with clipboard
  ///
  /// In en, this message translates to:
  /// **'Open Image Editor with Clipboard'**
  String get actionOpenEditorClipboard;

  /// Global action hint: open editor with clipboard
  ///
  /// In en, this message translates to:
  /// **'Open the Image Editor and load the clipboard image'**
  String get actionOpenEditorClipboardHint;

  /// Global action label: pin capture
  ///
  /// In en, this message translates to:
  /// **'Pin Screenshot'**
  String get actionPinCapture;

  /// Global action hint: pin capture
  ///
  /// In en, this message translates to:
  /// **'Screenshot a region straight to a floating pin'**
  String get actionPinCaptureHint;

  /// Global action label: pin clipboard
  ///
  /// In en, this message translates to:
  /// **'Pin Clipboard'**
  String get actionPinClipboard;

  /// Global action hint: pin clipboard
  ///
  /// In en, this message translates to:
  /// **'Float the clipboard image as a pin'**
  String get actionPinClipboardHint;

  /// Global action label: record a screen region
  ///
  /// In en, this message translates to:
  /// **'Record Region'**
  String get actionRecordRegion;

  /// Global action hint: record region
  ///
  /// In en, this message translates to:
  /// **'Record a screen region; press again to stop'**
  String get actionRecordRegionHint;

  /// Global action label: record the focused window
  ///
  /// In en, this message translates to:
  /// **'Record Window'**
  String get actionRecordWindow;

  /// Global action hint: record window
  ///
  /// In en, this message translates to:
  /// **'Record the focused window; press again to stop'**
  String get actionRecordWindowHint;

  /// Global action label: record the display under the cursor
  ///
  /// In en, this message translates to:
  /// **'Record Display'**
  String get actionRecordDisplay;

  /// Global action hint: record display
  ///
  /// In en, this message translates to:
  /// **'Record the display under the cursor; press again to stop'**
  String get actionRecordDisplayHint;

  /// Global action label: repeat the last recording region
  ///
  /// In en, this message translates to:
  /// **'Record Last Region'**
  String get actionRecordLastRegion;

  /// Global action hint: record last region
  ///
  /// In en, this message translates to:
  /// **'Repeat the last recording region; press again to stop'**
  String get actionRecordLastRegionHint;

  /// Tool name (toolbar tooltip + Settings > Shortcuts row, shared toolLabel source)
  ///
  /// In en, this message translates to:
  /// **'Select'**
  String get toolSelect;

  /// Tool name (toolbar tooltip + Settings > Shortcuts row, shared toolLabel source)
  ///
  /// In en, this message translates to:
  /// **'Crop'**
  String get toolCrop;

  /// Tool name (toolbar tooltip + Settings > Shortcuts row, shared toolLabel source)
  ///
  /// In en, this message translates to:
  /// **'Pin'**
  String get toolPin;

  /// Tool name for the crop slot in a recording live-select session (toolbar tooltip; part of the combined Shortcuts row title)
  ///
  /// In en, this message translates to:
  /// **'Record'**
  String get toolRecord;

  /// Tool name (toolbar tooltip + Settings > Shortcuts row, shared toolLabel source)
  ///
  /// In en, this message translates to:
  /// **'Crop / Pin / Record'**
  String get toolCropPinCombined;

  /// Tool name (toolbar tooltip + Settings > Shortcuts row, shared toolLabel source)
  ///
  /// In en, this message translates to:
  /// **'Blur'**
  String get toolBlur;

  /// Tool name (toolbar tooltip + Settings > Shortcuts row, shared toolLabel source)
  ///
  /// In en, this message translates to:
  /// **'Pixelate'**
  String get toolPixelate;

  /// Tool name (toolbar tooltip + Settings > Shortcuts row, shared toolLabel source)
  ///
  /// In en, this message translates to:
  /// **'Rectangle'**
  String get toolRectangle;

  /// Tool name (toolbar tooltip + Settings > Shortcuts row, shared toolLabel source)
  ///
  /// In en, this message translates to:
  /// **'Ellipse'**
  String get toolEllipse;

  /// Tool name (toolbar tooltip + Settings > Shortcuts row, shared toolLabel source)
  ///
  /// In en, this message translates to:
  /// **'Line'**
  String get toolLine;

  /// Tool name (toolbar tooltip + Settings > Shortcuts row, shared toolLabel source)
  ///
  /// In en, this message translates to:
  /// **'Arrow'**
  String get toolArrow;

  /// Tool name (toolbar tooltip + Settings > Shortcuts row, shared toolLabel source)
  ///
  /// In en, this message translates to:
  /// **'Pen'**
  String get toolPen;

  /// Tool name (toolbar tooltip + Settings > Shortcuts row, shared toolLabel source)
  ///
  /// In en, this message translates to:
  /// **'Text'**
  String get toolText;

  /// Tool name (toolbar tooltip + Settings > Shortcuts row, shared toolLabel source)
  ///
  /// In en, this message translates to:
  /// **'Highlighter'**
  String get toolHighlighter;

  /// Tool name (toolbar tooltip + Settings > Shortcuts row, shared toolLabel source)
  ///
  /// In en, this message translates to:
  /// **'Numbered step'**
  String get toolStep;

  /// Tool name (toolbar tooltip + Settings > Shortcuts row, shared toolLabel source)
  ///
  /// In en, this message translates to:
  /// **'Image stamp'**
  String get toolStamp;

  /// Tool name (toolbar tooltip + Settings > Shortcuts row, shared toolLabel source)
  ///
  /// In en, this message translates to:
  /// **'Magnify'**
  String get toolMagnify;

  /// Tool name (toolbar tooltip + Settings > Shortcuts row, shared toolLabel source)
  ///
  /// In en, this message translates to:
  /// **'Spotlight'**
  String get toolSpotlight;

  /// Toolbar: caption below the bar when pin mode is active
  ///
  /// In en, this message translates to:
  /// **'Pin mode: the selection floats as a pin'**
  String get toolbarPinCaption;

  /// Overlay toolbar caption during a recording live-select session
  ///
  /// In en, this message translates to:
  /// **'Record mode: the selection starts a recording'**
  String get toolbarRecordCaption;

  /// Record-mode toolbar: one-shot codec chip tooltip
  ///
  /// In en, this message translates to:
  /// **'Codec (this recording)'**
  String get toolbarRecordCodec;

  /// Record-mode toolbar: one-shot frame-rate chip tooltip
  ///
  /// In en, this message translates to:
  /// **'Frame rate (this recording)'**
  String get toolbarRecordFps;

  /// Recording control strip: the Finish (stop + save) button
  ///
  /// In en, this message translates to:
  /// **'Finish'**
  String get recordStripFinish;

  /// Recording control strip: the Pause button
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get recordStripPause;

  /// Recording control strip: the Resume button (while paused)
  ///
  /// In en, this message translates to:
  /// **'Resume'**
  String get recordStripResume;

  /// Recording control strip: the Abort (discard) button
  ///
  /// In en, this message translates to:
  /// **'Abort'**
  String get recordStripAbort;

  /// Recording control strip: the armed Abort confirm label
  ///
  /// In en, this message translates to:
  /// **'Confirm?'**
  String get recordStripConfirm;

  /// Recording control strip: GIF frame-count unit suffix (e.g. '120 frames')
  ///
  /// In en, this message translates to:
  /// **'frames'**
  String get recordStripFrames;

  /// Pre-recording countdown HUD: hint to click to cancel
  ///
  /// In en, this message translates to:
  /// **'Click to cancel'**
  String get recordCountdownCancel;

  /// Record-mode toolbar: one-shot cursor override toggle tooltip
  ///
  /// In en, this message translates to:
  /// **'Show cursor (this recording)'**
  String get toolbarRecordCursor;

  /// Record-mode toolbar: one-shot system-audio override toggle tooltip
  ///
  /// In en, this message translates to:
  /// **'System audio (this recording)'**
  String get toolbarRecordSystemAudio;

  /// Record-mode toolbar: one-shot microphone override toggle tooltip
  ///
  /// In en, this message translates to:
  /// **'Microphone (this recording)'**
  String get toolbarRecordMicrophone;

  /// Toolbar: crosshair-lines toggle tooltip when on
  ///
  /// In en, this message translates to:
  /// **'Crosshair lines: shown'**
  String get toolbarCrosshairShown;

  /// Toolbar: crosshair-lines toggle tooltip when off
  ///
  /// In en, this message translates to:
  /// **'Crosshair lines: hidden'**
  String get toolbarCrosshairHidden;

  /// Toolbar: pixel-loupe toggle tooltip when on
  ///
  /// In en, this message translates to:
  /// **'Pixel loupe: shown'**
  String get toolbarLoupeShown;

  /// Toolbar: pixel-loupe toggle tooltip when off
  ///
  /// In en, this message translates to:
  /// **'Pixel loupe: hidden'**
  String get toolbarLoupeHidden;

  /// Toolbar: cursor-toggle tooltip when the captured cursor layer is visible
  ///
  /// In en, this message translates to:
  /// **'Mouse pointer: shown'**
  String get toolbarMousePointerShown;

  /// Toolbar: cursor-toggle tooltip when the captured cursor layer is hidden
  ///
  /// In en, this message translates to:
  /// **'Mouse pointer: hidden'**
  String get toolbarMousePointerHidden;

  /// Toolbar > Stamp options: button label when no stamp image is set
  ///
  /// In en, this message translates to:
  /// **'Choose image…'**
  String get toolbarChooseImage;

  /// Toolbar > Stamp options: button label when a stamp image is already set
  ///
  /// In en, this message translates to:
  /// **'Change image…'**
  String get toolbarChangeImage;

  /// Toolbar > Stamp options: tooltip for the stamp image picker button
  ///
  /// In en, this message translates to:
  /// **'Choose a stamp image'**
  String get toolbarChooseStampImage;

  /// Toolbar > Text tool options: fill colour button tooltip (text background)
  ///
  /// In en, this message translates to:
  /// **'Background'**
  String get toolbarFillBackground;

  /// Toolbar > Shape tool options: fill colour button tooltip
  ///
  /// In en, this message translates to:
  /// **'Fill'**
  String get toolbarFill;

  /// Toolbar > Text tool options: outline colour button tooltip
  ///
  /// In en, this message translates to:
  /// **'Text outline'**
  String get toolbarTextOutline;

  /// Toolbar: default colour button tooltip
  ///
  /// In en, this message translates to:
  /// **'Colour'**
  String get toolbarColour;

  /// Toolbar: leading icon tooltip for blur strength stepper
  ///
  /// In en, this message translates to:
  /// **'Blur strength'**
  String get toolbarBlurStrength;

  /// Toolbar: leading icon tooltip for pixelate size stepper
  ///
  /// In en, this message translates to:
  /// **'Pixel size'**
  String get toolbarPixelSize;

  /// Toolbar: leading icon tooltip for stroke width stepper
  ///
  /// In en, this message translates to:
  /// **'Stroke width'**
  String get toolbarStrokeWidth;

  /// Toolbar > Rectangle options: radius pill label; {value} is the radius (e.g. '8 px' or 'Auto')
  ///
  /// In en, this message translates to:
  /// **'Radius: {value}'**
  String toolbarRadiusLabel(String value);

  /// Toolbar > Rectangle options: radius pill tooltip
  ///
  /// In en, this message translates to:
  /// **'Corner radius'**
  String get toolbarCornerRadius;

  /// Toolbar > Highlighter options: texture picker tooltip
  ///
  /// In en, this message translates to:
  /// **'Highlighter texture'**
  String get toolbarHighlighterTexture;

  /// Toolbar > Line/Arrow options: line style picker tooltip
  ///
  /// In en, this message translates to:
  /// **'Line style'**
  String get toolbarLineStyle;

  /// Toolbar: leading icon tooltip for curve-points stepper
  ///
  /// In en, this message translates to:
  /// **'Curve points'**
  String get toolbarCurvePoints;

  /// Toolbar > Arrow options: arrowheads picker tooltip
  ///
  /// In en, this message translates to:
  /// **'Arrowheads'**
  String get toolbarArrowheads;

  /// Toolbar > Arrow options: leading icon tooltip for arrowhead scale stepper
  ///
  /// In en, this message translates to:
  /// **'Arrowhead size'**
  String get toolbarArrowheadSize;

  /// Toolbar > Text tool options: leading icon tooltip for font size stepper
  ///
  /// In en, this message translates to:
  /// **'Font size'**
  String get toolbarFontSize;

  /// Toolbar > Step tool options: leading icon tooltip for badge size stepper
  ///
  /// In en, this message translates to:
  /// **'Badge size'**
  String get toolbarBadgeSize;

  /// Toolbar > Step tool options: leading icon tooltip for start-number stepper
  ///
  /// In en, this message translates to:
  /// **'Start number'**
  String get toolbarStartNumber;

  /// Toolbar > Step tool options: badge shape picker tooltip
  ///
  /// In en, this message translates to:
  /// **'Badge shape'**
  String get toolbarBadgeShape;

  /// Toolbar > Text tool options: font family button label when no custom font is chosen (system default font)
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get toolbarFontSystem;

  /// Toolbar > Spotlight options: leading icon tooltip for background dim stepper
  ///
  /// In en, this message translates to:
  /// **'Background dim'**
  String get toolbarBackgroundDim;

  /// Toolbar > Spotlight options: spotlight effect picker tooltip
  ///
  /// In en, this message translates to:
  /// **'Background treatment'**
  String get toolbarBackgroundTreatment;

  /// Toolbar > Spotlight options: leading icon tooltip for edge feather stepper
  ///
  /// In en, this message translates to:
  /// **'Edge feather'**
  String get toolbarEdgeFeather;

  /// Toolbar > Magnify options: leading icon tooltip for magnification stepper
  ///
  /// In en, this message translates to:
  /// **'Magnification'**
  String get toolbarMagnification;

  /// Toolbar: drop-shadow toggle tooltip when shadow is active
  ///
  /// In en, this message translates to:
  /// **'Drop shadow: on'**
  String get toolbarDropShadowOn;

  /// Toolbar: drop-shadow toggle tooltip when shadow is inactive
  ///
  /// In en, this message translates to:
  /// **'Drop shadow: off'**
  String get toolbarDropShadowOff;

  /// Toolbar > Magnify options: connector-line toggle tooltip when line is visible
  ///
  /// In en, this message translates to:
  /// **'Connector line: on'**
  String get toolbarConnectorLineOn;

  /// Toolbar > Magnify options: connector-line toggle tooltip when line is hidden
  ///
  /// In en, this message translates to:
  /// **'Connector line: off'**
  String get toolbarConnectorLineOff;

  /// Toolbar: tooltip on the reset-tool icon button
  ///
  /// In en, this message translates to:
  /// **'Reset this tool'**
  String get toolbarResetThisTool;

  /// Toolbar: selection action tooltip for duplicate
  ///
  /// In en, this message translates to:
  /// **'Duplicate'**
  String get toolbarDuplicate;

  /// Toolbar: selection action tooltip for bring-to-front
  ///
  /// In en, this message translates to:
  /// **'Bring to front'**
  String get toolbarBringToFront;

  /// Toolbar: selection action tooltip for send-to-back
  ///
  /// In en, this message translates to:
  /// **'Send to back'**
  String get toolbarSendToBack;

  /// Font picker popover: search field hint text
  ///
  /// In en, this message translates to:
  /// **'Search fonts…'**
  String get popoverSearchFonts;

  /// Font picker popover: pinned row label for the system default font
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get popoverFontSystem;

  /// Line style picker: solid line option
  ///
  /// In en, this message translates to:
  /// **'Solid'**
  String get lineStyleSolid;

  /// Line style picker: dashed line option
  ///
  /// In en, this message translates to:
  /// **'Dashed'**
  String get lineStyleDashed;

  /// Line style picker: dotted line option
  ///
  /// In en, this message translates to:
  /// **'Dotted'**
  String get lineStyleDotted;

  /// Line style picker: long-dash line option
  ///
  /// In en, this message translates to:
  /// **'Long dash'**
  String get lineStyleLongDash;

  /// Line style picker: dash-dot line option
  ///
  /// In en, this message translates to:
  /// **'Dash-dot'**
  String get lineStyleDashDot;

  /// Line style picker: dash-dot-dot line option
  ///
  /// In en, this message translates to:
  /// **'Dash-dot-dot'**
  String get lineStyleDashDotDot;

  /// Highlighter texture picker: clean texture option
  ///
  /// In en, this message translates to:
  /// **'Clean'**
  String get popoverTextureClean;

  /// Highlighter texture picker: streaks texture option
  ///
  /// In en, this message translates to:
  /// **'Streaks'**
  String get popoverTextureStreaks;

  /// Highlighter texture picker: frayed texture option
  ///
  /// In en, this message translates to:
  /// **'Frayed'**
  String get popoverTextureFrayed;

  /// Arrowheads picker: arrowhead at end only
  ///
  /// In en, this message translates to:
  /// **'End'**
  String get popoverArrowHeadEnd;

  /// Arrowheads picker: arrowhead at start only
  ///
  /// In en, this message translates to:
  /// **'Start'**
  String get popoverArrowHeadStart;

  /// Arrowheads picker: arrowheads at both ends
  ///
  /// In en, this message translates to:
  /// **'Both'**
  String get popoverArrowHeadBoth;

  /// Step badge shape picker: circle shape
  ///
  /// In en, this message translates to:
  /// **'Circle'**
  String get popoverStepShapeCircle;

  /// Step badge shape picker: square shape
  ///
  /// In en, this message translates to:
  /// **'Square'**
  String get popoverStepShapeSquare;

  /// Spotlight effect picker: dim-only option
  ///
  /// In en, this message translates to:
  /// **'Dim only'**
  String get popoverSpotlightEffectDimOnly;

  /// Spotlight effect picker: dim and blur option
  ///
  /// In en, this message translates to:
  /// **'Dim + Blur'**
  String get popoverSpotlightEffectDimBlur;

  /// Spotlight effect picker: dim and pixelate option
  ///
  /// In en, this message translates to:
  /// **'Dim + Pixelate'**
  String get popoverSpotlightEffectDimPixelate;

  /// Colour picker popover: eyedropper button tooltip
  ///
  /// In en, this message translates to:
  /// **'Pick a colour from the screen'**
  String get popoverPickColourFromScreen;

  /// Radius picker popover: title label
  ///
  /// In en, this message translates to:
  /// **'Corner radius'**
  String get popoverCornerRadius;

  /// Radius picker popover: Auto toggle label
  ///
  /// In en, this message translates to:
  /// **'Auto'**
  String get popoverRadiusAuto;

  /// Radius picker popover: hint below the Auto toggle
  ///
  /// In en, this message translates to:
  /// **'Radius scales with the rectangle’s size'**
  String get popoverRadiusAutoHint;

  /// Image Editor: window title bar label
  ///
  /// In en, this message translates to:
  /// **'Image Editor'**
  String get editorTitleBar;

  /// Image Editor landing card: headline copy
  ///
  /// In en, this message translates to:
  /// **'Open an image to edit'**
  String get editorOpenImage;

  /// Image Editor landing card: subtitle copy below the headline
  ///
  /// In en, this message translates to:
  /// **'Annotate, crop, and re-export any image in the same toolkit you use to screenshot.'**
  String get editorOpenImageSubtitle;

  /// Image Editor: Open button label (landing card and open bar)
  ///
  /// In en, this message translates to:
  /// **'Open Image…'**
  String get editorOpenImageButton;

  /// Image Editor: drag/paste hint below the Open button
  ///
  /// In en, this message translates to:
  /// **'or drag an image here · paste with ⌘V'**
  String get editorOpenImageHint;

  /// Image Editor gallery landing: section label above the recents grid
  ///
  /// In en, this message translates to:
  /// **'Recent'**
  String get editorGalleryRecent;

  /// Image Editor gallery: tooltip on the trailing More tile
  ///
  /// In en, this message translates to:
  /// **'Open the save folder in Finder'**
  String get editorGalleryMoreTooltip;

  /// Windows variant of editorGalleryMoreTooltip
  ///
  /// In en, this message translates to:
  /// **'Open the save folder in Explorer'**
  String get editorGalleryMoreTooltipWin;

  /// Image Editor gallery: caption on the trailing More tile
  ///
  /// In en, this message translates to:
  /// **'More…'**
  String get editorGalleryMoreCaption;

  /// Image Editor title bar: tooltip on the back-to-gallery home button
  ///
  /// In en, this message translates to:
  /// **'Home'**
  String get editorGalleryHome;

  /// Image Editor gallery context menu: open the file in the editor
  ///
  /// In en, this message translates to:
  /// **'Edit'**
  String get editorContextEdit;

  /// Image Editor gallery context menu: copy the image to clipboard
  ///
  /// In en, this message translates to:
  /// **'Copy Image'**
  String get editorContextCopyImage;

  /// Image Editor gallery context menu: copy the file path to clipboard
  ///
  /// In en, this message translates to:
  /// **'Copy Path'**
  String get editorContextCopyPath;

  /// Image Editor gallery context menu: share via the macOS share sheet
  ///
  /// In en, this message translates to:
  /// **'Share…'**
  String get editorContextShare;

  /// Image Editor gallery context menu: pin the image as a floating window
  ///
  /// In en, this message translates to:
  /// **'Pin to Screen'**
  String get editorContextPinToScreen;

  /// Image Editor gallery context menu: reveal the file in Finder
  ///
  /// In en, this message translates to:
  /// **'Show in Finder'**
  String get editorContextShowInFinder;

  /// Windows variant of editorContextShowInFinder
  ///
  /// In en, this message translates to:
  /// **'Show in Explorer'**
  String get editorContextShowInFinderWin;

  /// Image Editor gallery context menu: remove this entry from the recent list
  ///
  /// In en, this message translates to:
  /// **'Remove from Recent'**
  String get editorContextRemoveFromRecent;

  /// Image Editor gallery context menu: clear the entire recent list
  ///
  /// In en, this message translates to:
  /// **'Clear Recent'**
  String get editorContextClearRecent;

  /// Image Editor: title of the confirm-clear-recent dialog
  ///
  /// In en, this message translates to:
  /// **'Clear Recent?'**
  String get editorClearRecentTitle;

  /// Image Editor: body of the confirm-clear-recent dialog
  ///
  /// In en, this message translates to:
  /// **'Remove all {count} entries from the recent list? The image files themselves are not touched.'**
  String editorClearRecentMessage(int count);

  /// Image Editor: confirm button label for the clear-recent dialog
  ///
  /// In en, this message translates to:
  /// **'Clear'**
  String get editorClearRecentConfirm;

  /// Image Editor gallery: toast shown after copying a recent image to clipboard
  ///
  /// In en, this message translates to:
  /// **'Copied to clipboard'**
  String get editorToastCopiedToClipboard;

  /// Image Editor gallery: toast shown when copying a recent image fails
  ///
  /// In en, this message translates to:
  /// **'Copy failed'**
  String get editorToastCopyFailed;

  /// Image Editor: toast shown after copying a file path to clipboard
  ///
  /// In en, this message translates to:
  /// **'Path copied'**
  String get editorToastPathCopied;

  /// Image Editor: toast shown when pasting with no image in the clipboard
  ///
  /// In en, this message translates to:
  /// **'No image in clipboard'**
  String get editorToastNoImageInClipboard;

  /// Image Editor: toast shown when the clipboard image cannot be decoded
  ///
  /// In en, this message translates to:
  /// **'Cannot decode clipboard image'**
  String get editorToastCannotDecodeClipboard;

  /// Image Editor: toast shown when a file cannot be read
  ///
  /// In en, this message translates to:
  /// **'Cannot read file: {error}'**
  String editorToastCannotReadFile(String error);

  /// Image Editor: toast shown when a file image cannot be decoded
  ///
  /// In en, this message translates to:
  /// **'Cannot decode image: {error}'**
  String editorToastCannotDecodeImage(String error);

  /// Image Editor Done flow toast: copy leg succeeded
  ///
  /// In en, this message translates to:
  /// **'Copied'**
  String get editorToastCopied;

  /// Image Editor Done flow toast: copy leg failed
  ///
  /// In en, this message translates to:
  /// **'Copy failed'**
  String get editorToastCopyFlowFailed;

  /// Image Editor Done flow toast: save leg succeeded; {path} is the file path
  ///
  /// In en, this message translates to:
  /// **'Saved to {path}'**
  String editorToastSavedTo(String path);

  /// Image Editor Done flow toast: save leg failed
  ///
  /// In en, this message translates to:
  /// **'Save failed'**
  String get editorToastSaveFailed;

  /// Image Editor Done flow toast: copy-path leg failed
  ///
  /// In en, this message translates to:
  /// **'Copy path failed'**
  String get editorToastCopyPathFailed;

  /// Windows variant of editorToastRevealFailed (Explorer wording)
  ///
  /// In en, this message translates to:
  /// **'Reveal failed'**
  String get editorToastRevealFailedWin;

  /// Image Editor Done flow toast: show-in-Finder leg failed
  ///
  /// In en, this message translates to:
  /// **'Reveal failed'**
  String get editorToastRevealFailed;

  /// Image Editor Done flow toast: share-sheet leg failed
  ///
  /// In en, this message translates to:
  /// **'Share failed'**
  String get editorToastShareFailed;

  /// Image Editor Done flow toast: pin leg failed
  ///
  /// In en, this message translates to:
  /// **'Pin failed'**
  String get editorToastPinFailed;

  /// Image Editor Done flow toast: pin leg succeeded
  ///
  /// In en, this message translates to:
  /// **'Pinned'**
  String get editorToastPinned;

  /// Image Editor Done flow toast: all legs succeeded with no specific message
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get editorToastDone;

  /// Image Editor: title of the discard-unsaved-changes dialog
  ///
  /// In en, this message translates to:
  /// **'Discard changes?'**
  String get editorDiscardTitle;

  /// Image Editor: body of the discard-unsaved-changes dialog
  ///
  /// In en, this message translates to:
  /// **'You have unsaved annotations. Discard them?'**
  String get editorDiscardMessage;

  /// Image Editor toolbar: Done button label (runs the after-editor flow)
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get editorDoneButton;

  /// Image Editor toolbar: tooltip on the chevron button beside Done
  ///
  /// In en, this message translates to:
  /// **'One-off action (instead of the Done flow)'**
  String get editorMenuOneOffTooltip;

  /// Image Editor toolbar chevron menu: copy-only one-off action
  ///
  /// In en, this message translates to:
  /// **'Copy only'**
  String get editorMenuCopyOnly;

  /// Image Editor toolbar chevron menu: save-only one-off action
  ///
  /// In en, this message translates to:
  /// **'Save only'**
  String get editorMenuSaveOnly;

  /// Image Editor toolbar chevron menu: copy file path one-off action
  ///
  /// In en, this message translates to:
  /// **'Copy file path'**
  String get editorMenuCopyFilePath;

  /// Image Editor toolbar chevron menu: show in Finder one-off action
  ///
  /// In en, this message translates to:
  /// **'Show in Finder'**
  String get editorMenuShowInFinder;

  /// Windows variant of editorMenuShowInFinder
  ///
  /// In en, this message translates to:
  /// **'Show in Explorer'**
  String get editorMenuShowInFinderWin;

  /// Image Editor toolbar chevron menu: share one-off action
  ///
  /// In en, this message translates to:
  /// **'Share…'**
  String get editorMenuShare;

  /// Image Editor toolbar chevron menu: pin to screen one-off action
  ///
  /// In en, this message translates to:
  /// **'Pin to screen'**
  String get editorMenuPinToScreen;

  /// Image Editor toolbar: fit-to-window icon button tooltip
  ///
  /// In en, this message translates to:
  /// **'Fit to window (⌘1)'**
  String get editorViewFitToWindow;

  /// Image Editor toolbar: actual-size (100%) icon button tooltip
  ///
  /// In en, this message translates to:
  /// **'Actual size · 100% (⌘2)'**
  String get editorViewActualSize;

  /// Image Editor toolbar: undo icon button tooltip
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get editorUndoTooltip;

  /// Image Editor toolbar: redo icon button tooltip
  ///
  /// In en, this message translates to:
  /// **'Redo'**
  String get editorRedoTooltip;

  /// Editor crop confirm bar: confirm/crop button tooltip (Enter key also triggers)
  ///
  /// In en, this message translates to:
  /// **'Crop (Enter)'**
  String get editorCropConfirm;

  /// Editor crop confirm bar: cancel button tooltip (Esc key also triggers)
  ///
  /// In en, this message translates to:
  /// **'Cancel (Esc)'**
  String get editorCropCancel;

  /// 3e batch: masks/confirm/recorder/overlay
  ///
  /// In en, this message translates to:
  /// **'Settings open'**
  String get maskSettingsOpen;

  /// 3e batch: masks/confirm/recorder/overlay
  ///
  /// In en, this message translates to:
  /// **'Close the Settings window to continue.'**
  String get maskSettingsOpenHint;

  /// 3e batch: masks/confirm/recorder/overlay
  ///
  /// In en, this message translates to:
  /// **'Discard changes?'**
  String get confirmDiscardTitle;

  /// 3e batch: masks/confirm/recorder/overlay
  ///
  /// In en, this message translates to:
  /// **'You have unsaved annotations. Discard them?'**
  String get confirmDiscardMessage;

  /// 3e batch: masks/confirm/recorder/overlay
  ///
  /// In en, this message translates to:
  /// **'Discard'**
  String get confirmDiscard;

  /// 3e batch: masks/confirm/recorder/overlay
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get confirmCancel;

  /// 3e batch: masks/confirm/recorder/overlay
  ///
  /// In en, this message translates to:
  /// **'Disabled'**
  String get recorderDisabled;

  /// 3e batch: masks/confirm/recorder/overlay
  ///
  /// In en, this message translates to:
  /// **'Reserved key'**
  String get recorderReservedKey;

  /// Shortcut recorder: tooltip on the prohibition glyph that clears the binding (sets it to no shortcut)
  ///
  /// In en, this message translates to:
  /// **'Disable'**
  String get recorderDisable;

  /// 3e batch: masks/confirm/recorder/overlay
  ///
  /// In en, this message translates to:
  /// **'Press keys…'**
  String get recorderPressKeys;

  /// 3e batch: masks/confirm/recorder/overlay
  ///
  /// In en, this message translates to:
  /// **'Press Esc to cancel'**
  String get recorderEscToCancel;

  /// 3e batch: masks/confirm/recorder/overlay
  ///
  /// In en, this message translates to:
  /// **'Layers: {depth}/{cap}'**
  String layersCaption(int depth, int cap);

  /// 3e batch: masks/confirm/recorder/overlay
  ///
  /// In en, this message translates to:
  /// **'Layer replaced ({depth}/{cap})'**
  String layerReplacedNotice(int depth, int cap);

  /// 3e batch: masks/confirm/recorder/overlay
  ///
  /// In en, this message translates to:
  /// **'Oldest layer dropped ({depth}/{cap})'**
  String oldestLayerDroppedNotice(int depth, int cap);

  /// 3e batch: masks/confirm/recorder/overlay
  ///
  /// In en, this message translates to:
  /// **'Discard this layer?'**
  String get overlayDiscardLayerTitle;

  /// 3e batch: masks/confirm/recorder/overlay
  ///
  /// In en, this message translates to:
  /// **'You have unsaved annotations on this layer. Discard them and return to the layer below?'**
  String get overlayDiscardLayerMessage;

  /// 3e batch: masks/confirm/recorder/overlay
  ///
  /// In en, this message translates to:
  /// **'Discard screenshot?'**
  String get overlayDiscardCaptureTitle;

  /// 3e batch: masks/confirm/recorder/overlay
  ///
  /// In en, this message translates to:
  /// **'You have unsaved annotations on this screenshot. Discard them and exit?'**
  String get overlayDiscardCaptureMessage;

  /// 3e batch: masks/confirm/recorder/overlay
  ///
  /// In en, this message translates to:
  /// **'Pin failed'**
  String get overlayPinFailed;

  /// 3e batch: masks/confirm/recorder/overlay
  ///
  /// In en, this message translates to:
  /// **'Screenshot failed: {error}'**
  String overlayCaptureFailedError(String error);

  /// 3e batch: masks/confirm/recorder/overlay
  ///
  /// In en, this message translates to:
  /// **'Screenshot failed: not saved or copied'**
  String get overlayFailedNotSavedOrCopied;

  /// 3e batch: masks/confirm/recorder/overlay
  ///
  /// In en, this message translates to:
  /// **'Copied, but file save failed'**
  String get overlayFailedSave;

  /// 3e batch: masks/confirm/recorder/overlay
  ///
  /// In en, this message translates to:
  /// **'Saved, but clipboard failed'**
  String get overlayFailedClipboard;

  /// 3e batch: masks/confirm/recorder/overlay
  ///
  /// In en, this message translates to:
  /// **'Screenshot failed'**
  String get overlayCaptureFailedGeneric;

  /// Key-cap chips: shown when a binding is unbound
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get keyCapNone;

  /// GIF Editor: window title bar and native window title
  ///
  /// In en, this message translates to:
  /// **'GIF Editor'**
  String get gifEditorTitleBar;

  /// GIF Editor landing card: headline copy
  ///
  /// In en, this message translates to:
  /// **'Open a GIF to edit'**
  String get gifEditorOpenGif;

  /// GIF Editor landing card: subtitle copy below the headline
  ///
  /// In en, this message translates to:
  /// **'Trim frames, adjust timing, and export a new GIF.'**
  String get gifEditorOpenGifSubtitle;

  /// GIF Editor: Open button label on the landing card
  ///
  /// In en, this message translates to:
  /// **'Open GIF…'**
  String get gifEditorOpenGifButton;

  /// GIF Editor: primary export action label
  ///
  /// In en, this message translates to:
  /// **'Export GIF'**
  String get gifEditorExportButton;

  /// GIF Editor: tooltip on the play control
  ///
  /// In en, this message translates to:
  /// **'Play'**
  String get gifEditorPlay;

  /// GIF Editor: tooltip on the pause control
  ///
  /// In en, this message translates to:
  /// **'Pause'**
  String get gifEditorPause;

  /// GIF Editor stats: frame count
  ///
  /// In en, this message translates to:
  /// **'{count} frames'**
  String gifEditorStatsFrames(int count);

  /// GIF Editor: progress label while decoding an opened GIF
  ///
  /// In en, this message translates to:
  /// **'Opening GIF…'**
  String get gifEditorImporting;

  /// GIF Editor: error toast when a file fails to decode
  ///
  /// In en, this message translates to:
  /// **'Could not open this GIF'**
  String get gifEditorOpenFailed;

  /// GIF Editor: success toast after exporting
  ///
  /// In en, this message translates to:
  /// **'GIF exported'**
  String get gifEditorExportDone;

  /// GIF Editor: error toast when exporting fails
  ///
  /// In en, this message translates to:
  /// **'Export failed'**
  String get gifEditorExportFailed;

  /// GIF Editor: tooltip on the export options button and title of its popover
  ///
  /// In en, this message translates to:
  /// **'Export Options'**
  String get gifEditorExportOptions;

  /// GIF Editor export options: palette strategy row label
  ///
  /// In en, this message translates to:
  /// **'Palette'**
  String get gifEditorPalette;

  /// GIF Editor export options: one shared palette for the whole file
  ///
  /// In en, this message translates to:
  /// **'Global'**
  String get gifEditorPaletteGlobal;

  /// GIF Editor export options: a dedicated palette per frame
  ///
  /// In en, this message translates to:
  /// **'Per frame'**
  String get gifEditorPalettePerFrame;

  /// GIF Editor export options: error-diffusion toggle row label
  ///
  /// In en, this message translates to:
  /// **'Dithering'**
  String get gifEditorDither;

  /// GIF Editor export options: frame-diff size optimization toggle row label
  ///
  /// In en, this message translates to:
  /// **'Optimize file size'**
  String get gifEditorOptimize;

  /// GIF Editor export options: loop row label
  ///
  /// In en, this message translates to:
  /// **'Loop'**
  String get gifEditorLoop;

  /// GIF Editor export options: loop segment for endless playback
  ///
  /// In en, this message translates to:
  /// **'Forever'**
  String get gifEditorLoopForever;

  /// GIF Editor export options: loop segment for a finite play count
  ///
  /// In en, this message translates to:
  /// **'Count'**
  String get gifEditorLoopCount;

  /// GIF Editor timeline toolbar: undo tooltip
  ///
  /// In en, this message translates to:
  /// **'Undo'**
  String get gifEditorUndo;

  /// GIF Editor timeline toolbar: redo tooltip
  ///
  /// In en, this message translates to:
  /// **'Redo'**
  String get gifEditorRedo;

  /// GIF Editor timeline toolbar: delete selected frames tooltip
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get gifEditorDeleteFrames;

  /// GIF Editor timeline toolbar: move selected frames one slot left
  ///
  /// In en, this message translates to:
  /// **'Move left'**
  String get gifEditorMoveLeft;

  /// GIF Editor timeline toolbar: move selected frames one slot right
  ///
  /// In en, this message translates to:
  /// **'Move right'**
  String get gifEditorMoveRight;

  /// GIF Editor timeline toolbar: reverse frames tooltip
  ///
  /// In en, this message translates to:
  /// **'Reverse'**
  String get gifEditorReverse;

  /// GIF Editor timeline toolbar: append the reversed sequence (forward then back playback)
  ///
  /// In en, this message translates to:
  /// **'Yoyo'**
  String get gifEditorYoyo;

  /// GIF Editor timeline toolbar: collapse consecutive identical frames
  ///
  /// In en, this message translates to:
  /// **'Remove duplicates'**
  String get gifEditorRemoveDuplicates;

  /// GIF Editor timeline toolbar: reduce framerate popover trigger
  ///
  /// In en, this message translates to:
  /// **'Reduce frames'**
  String get gifEditorReduceFrames;

  /// GIF Editor reduce popover: explanation of the N picker
  ///
  /// In en, this message translates to:
  /// **'Keep the first of every N frames'**
  String get gifEditorReduceKeepFirst;

  /// GIF Editor timeline toolbar: delay operations popover trigger
  ///
  /// In en, this message translates to:
  /// **'Delay'**
  String get gifEditorDelay;

  /// GIF Editor delay popover: override mode (set delays to a value)
  ///
  /// In en, this message translates to:
  /// **'Set'**
  String get gifEditorDelaySet;

  /// GIF Editor delay popover: shift mode (add or subtract milliseconds)
  ///
  /// In en, this message translates to:
  /// **'Adjust'**
  String get gifEditorDelayAdjust;

  /// GIF Editor delay popover: scale mode (percentage)
  ///
  /// In en, this message translates to:
  /// **'Scale'**
  String get gifEditorDelayScale;

  /// GIF Editor popovers: apply button
  ///
  /// In en, this message translates to:
  /// **'Apply'**
  String get gifEditorApply;

  /// GIF Editor timeline toolbar: cut selected frames to the frame clipboard
  ///
  /// In en, this message translates to:
  /// **'Cut'**
  String get gifEditorCut;

  /// GIF Editor timeline toolbar: copy selected frames to the frame clipboard
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get gifEditorCopy;

  /// GIF Editor timeline toolbar: paste clipboard frames after the current frame
  ///
  /// In en, this message translates to:
  /// **'Paste'**
  String get gifEditorPaste;

  /// GIF Editor timeline toolbar: selection summary
  ///
  /// In en, this message translates to:
  /// **'{selected} of {total} selected'**
  String gifEditorSelectedCount(int selected, int total);

  /// GIF Editor toolbar: crop mode toggle tooltip
  ///
  /// In en, this message translates to:
  /// **'Crop'**
  String get gifEditorCrop;

  /// GIF Editor crop mode: hint shown before a rectangle is drawn
  ///
  /// In en, this message translates to:
  /// **'Drag on the preview to choose an area'**
  String get gifEditorCropHint;

  /// GIF Editor toolbar: resize panel trigger tooltip
  ///
  /// In en, this message translates to:
  /// **'Resize'**
  String get gifEditorResize;

  /// GIF Editor toolbar: mirror frames left-right
  ///
  /// In en, this message translates to:
  /// **'Flip horizontal'**
  String get gifEditorFlipH;

  /// GIF Editor toolbar: mirror frames top-bottom
  ///
  /// In en, this message translates to:
  /// **'Flip vertical'**
  String get gifEditorFlipV;

  /// GIF Editor toolbar: rotate frames a quarter turn counter-clockwise
  ///
  /// In en, this message translates to:
  /// **'Rotate left'**
  String get gifEditorRotateLeft;

  /// GIF Editor toolbar: rotate frames a quarter turn clockwise
  ///
  /// In en, this message translates to:
  /// **'Rotate right'**
  String get gifEditorRotateRight;

  /// GIF Editor resize panel: width field label
  ///
  /// In en, this message translates to:
  /// **'Width'**
  String get gifEditorWidth;

  /// GIF Editor resize panel: height field label
  ///
  /// In en, this message translates to:
  /// **'Height'**
  String get gifEditorHeight;

  /// GIF Editor resize panel: aspect-lock toggle label
  ///
  /// In en, this message translates to:
  /// **'Lock aspect ratio'**
  String get gifEditorKeepAspect;

  /// GIF Editor toolbar: label while a canvas transform runs (a percentage follows)
  ///
  /// In en, this message translates to:
  /// **'Processing'**
  String get gifEditorProcessing;

  /// GIF Editor crop confirm bar: cancel button
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get gifEditorCancel;

  /// GIF Editor: discard-confirm body when closing or replacing an edited document
  ///
  /// In en, this message translates to:
  /// **'You have unexported edits. Discard them?'**
  String get gifEditorDiscardMessage;

  /// GIF Editor toolbar: annotate (burn-in overlay) mode toggle tooltip
  ///
  /// In en, this message translates to:
  /// **'Annotate'**
  String get gifEditorAnnotate;

  /// GIF Editor annotate bar: target label when frames are selected
  ///
  /// In en, this message translates to:
  /// **'Apply to {n} selected frames'**
  String gifEditorBakeSelected(int n);

  /// GIF Editor annotate bar: target label when nothing is selected
  ///
  /// In en, this message translates to:
  /// **'Apply to all frames'**
  String get gifEditorBakeAll;

  /// GIF Editor toolbar: insert a blank black 1s frame before the playhead
  ///
  /// In en, this message translates to:
  /// **'Insert title frame'**
  String get gifEditorTitleFrame;

  /// GIF Editor toolbar: burn a playback progress bar onto every frame
  ///
  /// In en, this message translates to:
  /// **'Progress bar'**
  String get gifEditorProgressBar;

  /// GIF Editor toolbar: border panel trigger
  ///
  /// In en, this message translates to:
  /// **'Border'**
  String get gifEditorBorder;

  /// GIF Editor toolbar: transition panel trigger (generated in-between frames)
  ///
  /// In en, this message translates to:
  /// **'Transition'**
  String get gifEditorTransition;

  /// GIF Editor transition panel: crossfade mode
  ///
  /// In en, this message translates to:
  /// **'Fade'**
  String get gifEditorTransitionFade;

  /// GIF Editor transition panel: slide-in mode
  ///
  /// In en, this message translates to:
  /// **'Slide'**
  String get gifEditorTransitionSlide;

  /// GIF Editor transition panel: generated frame count field label
  ///
  /// In en, this message translates to:
  /// **'Frames'**
  String get gifEditorTransitionSteps;

  /// GIF Editor transition panel: slide enters from the left
  ///
  /// In en, this message translates to:
  /// **'Left'**
  String get gifEditorDirLeft;

  /// GIF Editor transition panel: slide enters from the right
  ///
  /// In en, this message translates to:
  /// **'Right'**
  String get gifEditorDirRight;

  /// GIF Editor transition panel: slide enters from the top
  ///
  /// In en, this message translates to:
  /// **'Top'**
  String get gifEditorDirUp;

  /// GIF Editor transition panel: slide enters from the bottom
  ///
  /// In en, this message translates to:
  /// **'Bottom'**
  String get gifEditorDirDown;

  /// GIF Editor toolbar: append a fade from the last frame back to the first
  ///
  /// In en, this message translates to:
  /// **'Smooth loop'**
  String get gifEditorSmoothLoop;

  /// GIF Editor toolbar: freeze everything outside a chosen region
  ///
  /// In en, this message translates to:
  /// **'Cinemagraph'**
  String get gifEditorCinemagraph;

  /// Tray menu: reveal the GIF Editor window
  ///
  /// In en, this message translates to:
  /// **'Open GIF Editor'**
  String get trayOpenGifEditor;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
