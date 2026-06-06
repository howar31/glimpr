import 'dart:io';
import '../capture/capture_kind.dart';
import '../output/filename.dart';
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
    this.saveToFile = true,
    this.copyToClipboard = true,
    this.rightClickExits = true,
    this.filenameTemplate = defaultFilenameTemplate,
    this.decorateSnap = false,
    this.decorateCrop = false,
    this.decorateWindow = false,
    this.decorateDisplay = false,
    this.decorateLastRegion = false,
    this.decorationJpegFill = 0xFFFFFFFF,
    this.captureCursor = false,
  });

  final Directory? saveDir;
  final ImageFormat format;
  final int jpegQuality; // 1-100; used only when format is jpeg
  final bool shutterSound;
  final bool completionSound;
  final bool saveToFile;
  final bool copyToClipboard;
  final bool rightClickExits; // right-click on empty space leaves capture mode
  final String filenameTemplate; // tokens: {date} {time} {title} {app}

  // Opt-in capture decoration (margin + rounded corners + drop shadow), gated
  // per capture scenario. All off by default => output is byte-identical.
  final bool decorateSnap; // overlay snap-to-window
  final bool decorateCrop; // overlay freehand crop rect
  final bool decorateWindow; // direct focused-window capture
  final bool decorateDisplay; // direct display capture
  final bool decorateLastRegion; // direct last-region capture
  final int decorationJpegFill; // ARGB; the JPEG margin fill colour
  final bool captureCursor; // include the mouse pointer in the capture

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
  static const _saveToFileKey = 'save_to_file';
  static const _copyToClipboardKey = 'copy_to_clipboard';
  static const _rightClickExitsKey = 'right_click_exits';
  static const _filenameTemplateKey = 'filename_template';
  static const _decorateSnapKey = 'decorate_snap';
  static const _decorateCropKey = 'decorate_crop';
  static const _decorateWindowKey = 'decorate_window';
  static const _decorateDisplayKey = 'decorate_display';
  static const _decorateLastRegionKey = 'decorate_last_region';
  static const _decorationJpegFillKey = 'decoration_jpeg_fill';
  static const _captureCursorKey = 'capture_cursor';

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

  // Delivery legs ----------------------------------------------------------
  Future<bool> getSaveToFile() async =>
      (await store.getBool(_saveToFileKey)) ?? true;
  Future<void> setSaveToFile(bool v) => store.setBool(_saveToFileKey, v);

  Future<bool> getCopyToClipboard() async =>
      (await store.getBool(_copyToClipboardKey)) ?? true;
  Future<void> setCopyToClipboard(bool v) =>
      store.setBool(_copyToClipboardKey, v);

  // Capture interaction --------------------------------------------------
  Future<bool> getRightClickExits() async =>
      (await store.getBool(_rightClickExitsKey)) ?? true;
  Future<void> setRightClickExits(bool v) =>
      store.setBool(_rightClickExitsKey, v);

  // Filename template ------------------------------------------------------
  Future<String> getFilenameTemplate() async {
    final s = await store.getString(_filenameTemplateKey);
    return (s == null || s.trim().isEmpty) ? defaultFilenameTemplate : s;
  }

  Future<void> setFilenameTemplate(String v) =>
      store.setString(_filenameTemplateKey, v);

  // Capture decoration (opt-in, per scenario) ----------------------------
  Future<bool> getDecorateSnap() async =>
      (await store.getBool(_decorateSnapKey)) ?? false;
  Future<void> setDecorateSnap(bool v) => store.setBool(_decorateSnapKey, v);

  Future<bool> getDecorateCrop() async =>
      (await store.getBool(_decorateCropKey)) ?? false;
  Future<void> setDecorateCrop(bool v) => store.setBool(_decorateCropKey, v);

  Future<bool> getDecorateWindow() async =>
      (await store.getBool(_decorateWindowKey)) ?? false;
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
      (await store.getInt(_decorationJpegFillKey)) ?? 0xFFFFFFFF;
  Future<void> setDecorationJpegFill(int argb) =>
      store.setInt(_decorationJpegFillKey, argb);

  // Capture mouse pointer ---------------------------------------------------
  Future<bool> getCaptureCursor() async =>
      (await store.getBool(_captureCursorKey)) ?? false;
  Future<void> setCaptureCursor(bool v) =>
      store.setBool(_captureCursorKey, v);

  /// One-shot snapshot of every capture-time setting (prefetched per capture).
  Future<CaptureSettings> loadCapture() async => CaptureSettings(
    saveDir: resolveSaveDir(await getSaveDirectory()),
    format: await getFormat(),
    jpegQuality: await getJpegQuality(),
    shutterSound: await getShutterSound(),
    completionSound: await getCompletionSound(),
    saveToFile: await getSaveToFile(),
    copyToClipboard: await getCopyToClipboard(),
    rightClickExits: await getRightClickExits(),
    filenameTemplate: await getFilenameTemplate(),
    decorateSnap: await getDecorateSnap(),
    decorateCrop: await getDecorateCrop(),
    decorateWindow: await getDecorateWindow(),
    decorateDisplay: await getDecorateDisplay(),
    decorateLastRegion: await getDecorateLastRegion(),
    decorationJpegFill: await getDecorationJpegFill(),
    captureCursor: await getCaptureCursor(),
  );
}

/// Maps a stored save-folder path to a Directory, or null when unset/empty so
/// the delivery path falls back to its built-in default.
Directory? resolveSaveDir(String? path) =>
    (path != null && path.isNotEmpty) ? Directory(path) : null;
