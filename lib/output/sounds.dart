import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Capture feedback cues, played NATIVELY: NSSound on macOS, PlaySound on
/// Windows, over the per-engine `glimpr/sound` channel (registered on every
/// engine, like `glimpr/clipboard`). This replaces the `audioplayers` package,
/// whose Windows backend raised an access violation when a cue played while a
/// recording's encoder was running.
///
/// The shutter fires at the instant the capture is committed (crop release /
/// window snap); the completion chime fires after the background save +
/// clipboard finish. The cue wavs are bundled assets: loaded once (cached) and
/// sent to native as raw bytes, so the native side needs no asset-path
/// resolution and just plays from memory.
const MethodChannel _sound = MethodChannel('glimpr/sound');

/// Loads a bundled asset's bytes. A seam so tests need no real asset bundle.
@visibleForTesting
Future<Uint8List> Function(String key) loadCueBytes =
    (key) async => (await rootBundle.load(key)).buffer.asUint8List();

final Map<String, Uint8List> _cache = {};

/// Clears the loaded-cue cache. Test-only (cues are cached for the process).
@visibleForTesting
void resetCueCacheForTest() => _cache.clear();

Future<void> _playCue(String id, String asset) async {
  final bytes = _cache[id] ??= await loadCueBytes(asset);
  await _sound.invokeMethod('play', {'id': id, 'bytes': bytes});
}

/// Camera-shutter click — at the moment of capture.
Future<void> playShutter() => _playCue('shutter', 'assets/sounds/shutter.wav');

/// Soft ascending two-note chime — once the capture is fully delivered.
Future<void> playComplete() =>
    _playCue('complete', 'assets/sounds/complete.wav');
