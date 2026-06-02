import 'dart:io';
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
  });

  final Directory? saveDir;
  final ImageFormat format;
  final int jpegQuality; // 1-100; used only when format is jpeg
  final bool shutterSound;
  final bool completionSound;
  final bool saveToFile;
  final bool copyToClipboard;

  static const defaults = CaptureSettings();

  bool get isJpeg => format == ImageFormat.jpeg;
  String get fileExtension => isJpeg ? 'jpg' : 'png';
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

  /// One-shot snapshot of every capture-time setting (prefetched per capture).
  Future<CaptureSettings> loadCapture() async => CaptureSettings(
    saveDir: resolveSaveDir(await getSaveDirectory()),
    format: await getFormat(),
    jpegQuality: await getJpegQuality(),
    shutterSound: await getShutterSound(),
    completionSound: await getCompletionSound(),
    saveToFile: await getSaveToFile(),
    copyToClipboard: await getCopyToClipboard(),
  );
}

/// Maps a stored save-folder path to a Directory, or null when unset/empty so
/// the delivery path falls back to its built-in default.
Directory? resolveSaveDir(String? path) =>
    (path != null && path.isNotEmpty) ? Directory(path) : null;
