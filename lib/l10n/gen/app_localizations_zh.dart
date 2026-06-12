// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get settingsLanguage => '語言';

  @override
  String get settingsPaneGeneral => '一般';

  @override
  String get settingsPaneCapture => '截圖';

  @override
  String get settingsPaneOutput => '輸出';

  @override
  String get settingsPaneWorkflow => '工作流程';

  @override
  String get settingsPaneShortcuts => '快捷鍵';

  @override
  String get settingsPaneAdvanced => '進階';

  @override
  String get settingsSectionStartup => '啟動';

  @override
  String get settingsLaunchAtLogin => '登入時啟動';

  @override
  String get settingsLaunchAtLoginHint => '登入時自動啟動 Glimpr';

  @override
  String get settingsLanguageAppliesAfterRestart => '重新啟動 Glimpr 後生效';

  @override
  String get settingsRestartNotice => '重新啟動 Glimpr 後此設定才會生效。';

  @override
  String get settingsRestartNow => '立即重新啟動 Glimpr';

  @override
  String get settingsRestartNowConfirm => '再按一次以重新啟動 Glimpr';

  @override
  String get settingsSectionBehaviour => '行為';

  @override
  String get settingsMousePointer => '滑鼠指標';

  @override
  String get settingsMousePointerHint =>
      '在截圖中包含滑鼠指標。此為預設值；截圖時工具列上的按鈕可單次顯示或隱藏指標，不會改變這個設定。';

  @override
  String get settingsRightClickExits => '按右鍵離開';

  @override
  String get settingsRightClickExitsHint => '按右鍵離開截圖模式（Esc 永遠有效）';

  @override
  String get settingsConfirmBeforeDiscarding => '捨棄前先確認';

  @override
  String get settingsConfirmBeforeDiscardingHint =>
      '離開仍有標註的截圖時（右鍵或 Esc），先詢問再捨棄。';

  @override
  String get settingsSectionLoupe => '放大鏡';

  @override
  String get settingsLoupeDescription =>
      '裁切、模糊、像素化工具的像素放大鏡，在截圖與圖片編輯器中皆可使用。可用方向鍵逐像素微調游標。';

  @override
  String get settingsLoupeSize => '大小';

  @override
  String get settingsLoupeSizeHint => '每邊顯示的像素數';

  @override
  String get settingsLoupeMagnification => '放大倍率';

  @override
  String get settingsLoupeMagnificationHint => '每個像素繪製的大小';

  @override
  String get settingsLoupePreviewReduced => '預覽已縮小以符合空間';

  @override
  String get settingsLoupeReset => '重設';

  @override
  String get settingsToolShortcutsWhileSampling => '取色時的工具快捷鍵';

  @override
  String get settingsToolShortcutsWhileSamplingHint =>
      '「切換工具」會立即結束取色；「繼續取色」會忽略工具按鍵，避免誤觸按鍵打斷瞄準。';

  @override
  String get settingsSwitchTool => '切換工具';

  @override
  String get settingsKeepSampling => '繼續取色';

  @override
  String get settingsSectionOverlayHUD => '截圖輔助顯示';

  @override
  String get settingsCrosshair => '十字線';

  @override
  String get settingsCrosshairHint => '為區域工具（裁切、模糊、像素化）顯示全螢幕十字線。中央準星與放大鏡不受影響。';

  @override
  String get settingsAnimateMarchingAnts => '虛線框動畫';

  @override
  String get settingsAnimateMarchingAntsHint =>
      '讓選取範圍、十字線與視窗外框的虛線流動。關閉後為靜態虛線（動態較少，也稍省資源）。';

  @override
  String get settingsSectionAfterCapture => '截圖後';

  @override
  String get settingsSectionAfterEditorDone => '編輯器完成後';

  @override
  String get settingsSectionSounds => '音效';

  @override
  String get settingsFlowCopyToClipboard => '複製到剪貼簿';

  @override
  String get settingsFlowCopyToClipboardHint => '將圖片放上剪貼簿';

  @override
  String get settingsFlowSaveToFile => '儲存為檔案';

  @override
  String get settingsFlowSaveToFileHint => '將圖片寫入儲存資料夾';

  @override
  String get settingsFlowCopyFilePath => '複製檔案路徑';

  @override
  String get settingsFlowCopyFilePathHint => '將已儲存檔案的路徑放上剪貼簿（而非圖片本身）';

  @override
  String get settingsFlowCopyFilePathNeedsSave => '需要「儲存為檔案」';

  @override
  String get settingsFlowShowInFinder => '顯示於 Finder';

  @override
  String get settingsFlowShowInFinderHint => '在 Finder 中顯示已儲存的檔案';

  @override
  String get settingsFlowOpenInEditor => '以編輯器開啟';

  @override
  String get settingsFlowOpenInEditorHint => '在圖片編輯器中開啟結果以繼續編輯';

  @override
  String get settingsFlowShareSheet => '分享選單';

  @override
  String get settingsFlowShareSheetHint => '開啟 macOS 分享選單（AirDrop、訊息等）';

  @override
  String get settingsFlowPinToScreen => '釘選到螢幕';

  @override
  String get settingsFlowPinToScreenCaptureHint => '將截圖固定為最上層浮動視窗，釘在原本截取的位置';

  @override
  String get settingsFlowPinToScreenEditorHint => '將結果固定為最上層浮動視窗（置中）';

  @override
  String get settingsFlowCaptureCaption =>
      '在確認截圖時執行：截圖畫面的 ✓/Enter 與 ⌘⌥2/3/4 直接截圖模式。';

  @override
  String get settingsFlowEditorCaption =>
      '在按下編輯器的「完成」按鈕（或 Enter）時執行；「完成」旁的 ▾ 選單提供單次替代動作。';

  @override
  String get settingsFlowCaptureCaptionEmpty =>
      '在確認截圖時執行：截圖畫面的 ✓/Enter 與 ⌘⌥2/3/4 直接截圖模式。目前未選取任何動作，將改為複製到剪貼簿。';

  @override
  String get settingsFlowEditorCaptionEmpty =>
      '在按下編輯器的「完成」按鈕（或 Enter）時執行；「完成」旁的 ▾ 選單提供單次替代動作。目前未選取任何動作，將改為複製到剪貼簿。';

  @override
  String get settingsSoundShutter => '快門';

  @override
  String get settingsSoundShutterHint => '在截圖的瞬間播放';

  @override
  String get settingsSoundCompletion => '完成';

  @override
  String get settingsSoundCompletionHint => '完成流程結束時播放提示音';

  @override
  String get settingsSectionSaveLocation => '儲存位置';

  @override
  String get settingsSectionFormat => '格式';

  @override
  String get settingsSectionFilename => '檔名';

  @override
  String get settingsSectionDecoration => '裝飾';

  @override
  String get settingsSectionRecentHistory => '最近記錄';

  @override
  String get settingsSaveFolder => '儲存資料夾';

  @override
  String get settingsSaveFolderChoose => '選擇…';

  @override
  String get settingsSaveFolderReset => '重設';

  @override
  String get settingsSaveFolderDefault => '預設 · ~/Pictures/Glimpr';

  @override
  String get settingsFormatQuality => '品質';

  @override
  String get settingsFormatQualityHint => '壓縮程度';

  @override
  String get settingsFilenamePreview => '預覽';

  @override
  String get settingsFilenamePlaceholders => '可用變數';

  @override
  String get settingsFilenameTokenWindowDesc => '視窗標題；若沒有標題則為 App 名稱';

  @override
  String get settingsFilenameTokenAppDesc => '應用程式名稱（例如 Safari）';

  @override
  String get settingsFilenameTokenDateDesc => '截圖日期，例如 2026-06-03';

  @override
  String get settingsFilenameTokenTimeDesc => '截圖時間，例如 15-04-09';

  @override
  String settingsFilenameNote(String windowToken, String appToken) {
    return '使用截圖結束時游標所在的視窗。在桌面上時，$windowToken 與 $appToken 會被省略。';
  }

  @override
  String get settingsDecorationWindowSnap => '視窗框選';

  @override
  String get settingsDecorationWindowSnapHint => '框選視窗截圖時加上陰影與邊距';

  @override
  String get settingsDecorationFreehandCrop => '手動框選';

  @override
  String get settingsDecorationFreehandCropHint => '拖曳框選的區域加上陰影與邊距';

  @override
  String get settingsDecorationFocusedWindow => '目前視窗';

  @override
  String get settingsDecorationFocusedWindowHint => '截取目前視窗模式（⌘⌥2）';

  @override
  String get settingsDecorationDisplay => '螢幕';

  @override
  String get settingsDecorationDisplayHint => '截取螢幕模式（⌘⌥3）';

  @override
  String get settingsDecorationLastRegion => '上次範圍';

  @override
  String get settingsDecorationLastRegionHint => '截取上次範圍模式（⌘⌥4）';

  @override
  String get settingsDecorationJpegFill => 'JPEG 背景填色';

  @override
  String get settingsDecorationJpegFillHint => '儲存為 JPEG 時邊距後方的顏色';

  @override
  String get settingsDecorationPinNote =>
      '裝飾僅套用於輸出的圖片（檔案、剪貼簿、分享、編輯器）；釘選一律使用未裝飾的原圖。';

  @override
  String get settingsRecentImagesKept => '保留的最近圖片數';

  @override
  String get settingsRecentImagesKeptHint => '編輯器起始頁與選單列「開啟最近項目」保留的圖片數量。';

  @override
  String get settingsSectionMultiDisplay => '多螢幕';

  @override
  String get settingsWarmEnginesTitle => '預熱截圖引擎';

  @override
  String get settingsWarmEnginesBody =>
      'Glimpr 保持隨時可截圖的螢幕數量，包含 App 啟動後才接上的螢幕（例如接上 dock）。Glimpr 為每個螢幕預熱一個繪製引擎，凍結畫面因此能毫無延遲地出現。\n\n這是下限而非上限：Glimpr 啟動時已連接的每個螢幕一定會有預熱引擎，這個數字只決定為之後插入的螢幕預留多少備用引擎。\n\n成本：Glimpr 執行期間每個引擎約占用 10 MB 記憶體。超出此數量的新螢幕仍可截圖，但只會顯示凍結畫面；重新啟動後其十字線與工具列即可正常跟隨（所有已連接螢幕會重新預熱）。';

  @override
  String get settingsWarmEnginesDefault => '預設 2 · 重新啟動 Glimpr 後生效';

  @override
  String get settingsSectionCaptureLayers => '截圖圖層';

  @override
  String get settingsCaptureLayersTitle => '截圖圖層';

  @override
  String get settingsCaptureLayersBody =>
      '在截圖進行中再次按下截圖快捷鍵，會在上方疊加一張新的凍結畫面（前一層會原樣留在截圖中，包含所有標註）；完成或取消一層後會回到下面那層。\n\n設為 1（預設）時不會疊層：截圖中再次觸發會重新開始並捨棄標註。設為 2 到 5 時，達到上限後會丟棄最底部的「最舊」圖層，保留最近的圖層；兩種情況工具列都會提示。\n\n成本：截圖進行期間，每個疊起的圖層在每個螢幕各保留一張全解析度凍結圖片（4K 或 5K 約 30 到 60 MB）。下次截圖時生效；無需重新啟動。';

  @override
  String get settingsSectionToolStyles => '工具樣式';

  @override
  String get settingsResetAllToolStyles => '重設所有工具樣式';

  @override
  String get settingsResetAllToolStylesHint =>
      '將每個標註工具（顏色、線寬、字級、字體）恢復為預設值。下次截圖時生效。';

  @override
  String get settingsResetAllToolStylesConfirm => '再按一次以重設所有工具樣式';

  @override
  String get settingsShortcutsCaptureNote => '全域生效，因此需要修飾鍵（⌘ ⌥ ⌃ ⇧）';

  @override
  String get settingsCmdUndo => '復原';

  @override
  String get settingsCmdRedo => '重做';

  @override
  String get settingsCmdPasteImage => '貼上圖片';

  @override
  String get settingsCmdPasteImageHint => '從剪貼簿';

  @override
  String get settingsCmdDeleteSelected => '刪除所選';

  @override
  String get settingsCmdDeleteSelectedHint => '移除選取的標註';

  @override
  String get settingsCmdExport => '輸出';

  @override
  String get settingsCmdExportHint => '截取框選的視窗，或整個螢幕';

  @override
  String get settingsCmdDuplicateSelected => '再製所選';

  @override
  String get settingsCmdDuplicateSelectedHint => '再製選取的標註';

  @override
  String get settingsCmdBringToFront => '移至最前';

  @override
  String get settingsCmdBringToFrontHint => '將選取項目移到其他標註之上';

  @override
  String get settingsCmdSendToBack => '移至最後';

  @override
  String get settingsCmdSendToBackHint => '將選取項目移到其他標註之下';

  @override
  String get settingsCmdCopyHex => '以 HEX 複製顏色';

  @override
  String get settingsCmdCopyColorHint => '取色器取樣時可用';

  @override
  String get settingsCmdCopyRgb => '以 RGB 複製顏色';

  @override
  String get settingsCmdCopyHsl => '以 HSL 複製顏色';

  @override
  String get settingsReservedCancelExit => '取消／離開';

  @override
  String get settingsReservedHint => '保留';

  @override
  String get settingsReservedCloseWindow => '關閉視窗';

  @override
  String get settingsReservedHintEditorSettings => '保留 · 編輯器／設定';

  @override
  String get settingsReservedOpenSettings => '開啟設定';

  @override
  String get settingsReservedHintOverlayEditor => '保留 · 截圖／編輯器';

  @override
  String get settingsReservedNudgeCrosshair => '微調十字線';

  @override
  String get settingsReservedHintRegionTools => '保留 · 區域工具';

  @override
  String get settingsReservedFitToWindow => '符合視窗大小';

  @override
  String get settingsReservedHintImageEditor => '保留 · 圖片編輯器';

  @override
  String get settingsReservedZoomTo100 => '縮放至 100%';

  @override
  String get settingsReservedCommitText => '確認文字';

  @override
  String get settingsReservedHintWhileEditingText => '保留 · 編輯文字時';

  @override
  String get settingsReservedNewLine => '換行';

  @override
  String get settingsReservedCancelText => '取消文字';

  @override
  String get settingsShortcutsNeedsModifier => '需要修飾鍵';

  @override
  String get settingsShortcutsDuplicate => '重複';

  @override
  String get settingsShortcutsResetToDefault => '重設為預設值';

  @override
  String get settingsShortcutsRevert => '還原';

  @override
  String get settingsShortcutsApply => '套用';

  @override
  String get settingsShortcutsTools => '工具';

  @override
  String get settingsShortcutsCommands => '指令';

  @override
  String get settingsShortcutsReserved => '保留';

  @override
  String get actionCapture => '截圖';

  @override
  String get actionCaptureHint => '開始螢幕截圖';

  @override
  String get actionCaptureWindow => '截取視窗';

  @override
  String get actionCaptureWindowHint => '截取目前的視窗';

  @override
  String get actionCaptureDisplay => '截取螢幕';

  @override
  String get actionCaptureDisplayHint => '截取游標所在的螢幕';

  @override
  String get actionCaptureLastRegion => '截取上次範圍';

  @override
  String get actionCaptureLastRegionHint => '重複上一次的截圖範圍';

  @override
  String get actionOpenEditor => '開啟編輯器';

  @override
  String get actionOpenEditorHint => '開啟圖片編輯器';

  @override
  String get actionOpenEditorClipboard => '以剪貼簿開啟編輯器';

  @override
  String get actionOpenEditorClipboardHint => '開啟圖片編輯器並載入剪貼簿圖片';

  @override
  String get actionPinCapture => '釘選截圖';

  @override
  String get actionPinCaptureHint => '框選範圍並直接釘選為浮動視窗';

  @override
  String get actionPinClipboard => '釘選剪貼簿';

  @override
  String get actionPinClipboardHint => '將剪貼簿圖片釘選為浮動視窗';

  @override
  String get toolSelect => '選取';

  @override
  String get toolCrop => '裁切';

  @override
  String get toolPin => '釘選';

  @override
  String get toolCropPinCombined => '裁切／釘選';

  @override
  String get toolBlur => '模糊';

  @override
  String get toolPixelate => '像素化';

  @override
  String get toolRectangle => '矩形';

  @override
  String get toolEllipse => '橢圓';

  @override
  String get toolLine => '直線';

  @override
  String get toolArrow => '箭頭';

  @override
  String get toolPen => '畫筆';

  @override
  String get toolText => '文字';

  @override
  String get toolHighlighter => '螢光筆';

  @override
  String get toolStep => '編號標記';

  @override
  String get toolStamp => '圖片印章';

  @override
  String get toolMagnify => '放大';

  @override
  String get toolSpotlight => '聚光燈';

  @override
  String get toolbarPinCaption => '釘選模式：選取範圍將浮動為釘選';

  @override
  String get toolbarMousePointerShown => '滑鼠指標：顯示';

  @override
  String get toolbarMousePointerHidden => '滑鼠指標：隱藏';

  @override
  String get toolbarChooseImage => '選擇圖片…';

  @override
  String get toolbarChangeImage => '更換圖片…';

  @override
  String get toolbarChooseStampImage => '選擇印章圖片';

  @override
  String get toolbarFillBackground => '背景';

  @override
  String get toolbarFill => '填滿';

  @override
  String get toolbarTextOutline => '文字外框';

  @override
  String get toolbarColour => '顏色';

  @override
  String get toolbarBlurStrength => '模糊強度';

  @override
  String get toolbarPixelSize => '像素大小';

  @override
  String get toolbarStrokeWidth => '線寬';

  @override
  String toolbarRadiusLabel(String value) {
    return '圓角：$value';
  }

  @override
  String get toolbarCornerRadius => '圓角';

  @override
  String get toolbarHighlighterTexture => '螢光筆紋理';

  @override
  String get toolbarLineStyle => '線條樣式';

  @override
  String get toolbarCurvePoints => '曲線控制點';

  @override
  String get toolbarArrowheads => '箭頭端點';

  @override
  String get toolbarArrowheadSize => '箭頭大小';

  @override
  String get toolbarFontSize => '字級';

  @override
  String get toolbarBadgeSize => '標記大小';

  @override
  String get toolbarStartNumber => '起始編號';

  @override
  String get toolbarBadgeShape => '標記形狀';

  @override
  String get toolbarFontSystem => '系統';

  @override
  String get toolbarBackgroundDim => '背景調暗';

  @override
  String get toolbarBackgroundTreatment => '背景處理';

  @override
  String get toolbarEdgeFeather => '邊緣羽化';

  @override
  String get toolbarMagnification => '放大倍率';

  @override
  String get toolbarDropShadowOn => '陰影：開';

  @override
  String get toolbarDropShadowOff => '陰影：關';

  @override
  String get toolbarConnectorLineOn => '連接線：開';

  @override
  String get toolbarConnectorLineOff => '連接線：關';

  @override
  String get toolbarResetThisTool => '重設此工具';

  @override
  String get toolbarDuplicate => '再製';

  @override
  String get toolbarBringToFront => '移至最前';

  @override
  String get toolbarSendToBack => '移至最後';

  @override
  String get popoverSearchFonts => '搜尋字體…';

  @override
  String get popoverFontSystem => '系統';

  @override
  String get lineStyleSolid => '實線';

  @override
  String get lineStyleDashed => '虛線';

  @override
  String get lineStyleDotted => '點線';

  @override
  String get lineStyleLongDash => '長虛線';

  @override
  String get lineStyleDashDot => '點劃線';

  @override
  String get lineStyleDashDotDot => '雙點劃線';

  @override
  String get popoverTextureClean => '平整';

  @override
  String get popoverTextureStreaks => '筆痕';

  @override
  String get popoverTextureFraged => '毛邊';

  @override
  String get popoverArrowHeadEnd => '終點';

  @override
  String get popoverArrowHeadStart => '起點';

  @override
  String get popoverArrowHeadBoth => '兩端';

  @override
  String get popoverStepShapeCircle => '圓形';

  @override
  String get popoverStepShapeSquare => '方形';

  @override
  String get popoverSpotlightEffectDimOnly => '僅調暗';

  @override
  String get popoverSpotlightEffectDimBlur => '調暗＋模糊';

  @override
  String get popoverSpotlightEffectDimPixelate => '調暗＋像素化';

  @override
  String get popoverPickColourFromScreen => '從畫面取色';

  @override
  String get popoverCornerRadius => '圓角';

  @override
  String get popoverRadiusAuto => '自動';

  @override
  String get popoverRadiusAutoHint => '圓角隨矩形大小縮放';

  @override
  String get editorTitleBar => '圖片編輯器';

  @override
  String get editorOpenImage => '開啟圖片以編輯';

  @override
  String get editorOpenImageSubtitle => '以截圖時使用的同一套工具為任何圖片加上標註、裁切並重新輸出。';

  @override
  String get editorOpenImageButton => '開啟圖片…';

  @override
  String get editorOpenImageHint => '或將圖片拖曳至此 · 以 ⌘V 貼上';

  @override
  String get editorGalleryRecent => '最近';

  @override
  String get editorGalleryMoreTooltip => '在 Finder 中開啟儲存資料夾';

  @override
  String get editorGalleryMoreCaption => '更多…';

  @override
  String get editorGalleryHome => '首頁';

  @override
  String get editorContextEdit => '編輯';

  @override
  String get editorContextCopyImage => '複製圖片';

  @override
  String get editorContextCopyPath => '複製路徑';

  @override
  String get editorContextShare => '分享…';

  @override
  String get editorContextPinToScreen => '釘選到螢幕';

  @override
  String get editorContextShowInFinder => '顯示於 Finder';

  @override
  String get editorContextRemoveFromRecent => '從最近項目移除';

  @override
  String get editorContextClearRecent => '清除最近項目';

  @override
  String get editorClearRecentTitle => '清除最近項目？';

  @override
  String editorClearRecentMessage(int count) {
    return '從最近列表移除全部 $count 個項目？圖片檔案本身不會被更動。';
  }

  @override
  String get editorClearRecentConfirm => '清除';

  @override
  String get editorToastCopiedToClipboard => '已複製到剪貼簿';

  @override
  String get editorToastCopyFailed => '複製失敗';

  @override
  String get editorToastPathCopied => '已複製路徑';

  @override
  String get editorToastNoImageInClipboard => '剪貼簿中沒有圖片';

  @override
  String get editorToastCannotDecodeClipboard => '無法解碼剪貼簿圖片';

  @override
  String editorToastCannotReadFile(String error) {
    return '無法讀取檔案：$error';
  }

  @override
  String editorToastCannotDecodeImage(String error) {
    return '無法解碼圖片：$error';
  }

  @override
  String get editorToastCopied => '已複製';

  @override
  String get editorToastCopyFlowFailed => '複製失敗';

  @override
  String editorToastSavedTo(String path) {
    return '已儲存至 $path';
  }

  @override
  String get editorToastSaveFailed => '儲存失敗';

  @override
  String get editorToastCopyPathFailed => '複製路徑失敗';

  @override
  String get editorToastRevealFailed => '無法在 Finder 中顯示';

  @override
  String get editorToastShareFailed => '分享失敗';

  @override
  String get editorToastPinFailed => '釘選失敗';

  @override
  String get editorToastPinned => '已釘選';

  @override
  String get editorToastDone => '完成';

  @override
  String get editorDiscardTitle => '捨棄變更？';

  @override
  String get editorDiscardMessage => '尚有未儲存的標註。要捨棄嗎？';

  @override
  String get editorDoneButton => '完成';

  @override
  String get editorMenuOneOffTooltip => '單次動作（不執行「完成」流程）';

  @override
  String get editorMenuCopyOnly => '僅複製';

  @override
  String get editorMenuSaveOnly => '僅儲存';

  @override
  String get editorMenuCopyFilePath => '複製檔案路徑';

  @override
  String get editorMenuShowInFinder => '顯示於 Finder';

  @override
  String get editorMenuShare => '分享…';

  @override
  String get editorMenuPinToScreen => '釘選到螢幕';

  @override
  String get editorViewFitToWindow => '符合視窗大小（⌘1）';

  @override
  String get editorViewActualSize => '實際大小 · 100%（⌘2）';

  @override
  String get editorUndoTooltip => '復原';

  @override
  String get editorRedoTooltip => '重做';

  @override
  String get editorCropConfirm => '裁切（Enter）';

  @override
  String get editorCropCancel => '取消（Esc）';

  @override
  String get maskSettingsOpen => '設定視窗開啟中';

  @override
  String get maskSettingsOpenHint => '關閉設定視窗後即可繼續。';

  @override
  String get confirmDiscardTitle => '捨棄變更？';

  @override
  String get confirmDiscardMessage => '尚有未儲存的標註。要捨棄嗎？';

  @override
  String get confirmDiscard => '捨棄';

  @override
  String get confirmCancel => '取消';

  @override
  String get recorderDisabled => '停用';

  @override
  String get recorderReservedKey => '保留按鍵';

  @override
  String get recorderNeedsModifier => '需要修飾鍵（⌘ ⌥ ⌃ ⇧）';

  @override
  String get recorderClear => '清除';

  @override
  String get recorderPressKeys => '請按下按鍵…';

  @override
  String get recorderEscToCancel => '按 Esc 取消';

  @override
  String layersCaption(int depth, int cap) {
    return '圖層：$depth/$cap';
  }

  @override
  String layerReplacedNotice(int depth, int cap) {
    return '已取代圖層（$depth/$cap）';
  }

  @override
  String oldestLayerDroppedNotice(int depth, int cap) {
    return '已丟棄最舊圖層（$depth/$cap）';
  }

  @override
  String get overlayDiscardLayerTitle => '捨棄此圖層？';

  @override
  String get overlayDiscardLayerMessage => '此圖層尚有未儲存的標註。要捨棄並回到下一層嗎？';

  @override
  String get overlayDiscardCaptureTitle => '捨棄截圖？';

  @override
  String get overlayDiscardCaptureMessage => '此截圖尚有未儲存的標註。要捨棄並離開嗎？';

  @override
  String get overlayPinFailed => '釘選失敗';

  @override
  String overlayCaptureFailedError(String error) {
    return '截圖失敗：$error';
  }

  @override
  String get overlayFailedNotSavedOrCopied => '截圖失敗：未儲存也未複製';

  @override
  String get overlayFailedSave => '已複製，但檔案儲存失敗';

  @override
  String get overlayFailedClipboard => '已儲存，但複製到剪貼簿失敗';

  @override
  String get overlayCaptureFailedGeneric => '截圖失敗';

  @override
  String get keyCapNone => '無';
}
