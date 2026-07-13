import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'frame_store.dart';
import 'gif_document.dart';
import 'gif_import.dart';

/// State owner for one GIF Editor window: the open document, the current
/// frame, and playback. Widgets listen; edit operations land here in later
/// slices so the undo model has a single home.
class GifEditorController extends ChangeNotifier {
  FrameStore? _store;
  GifDocument? _doc;
  int _current = 0;
  bool _playing = false;
  bool _opening = false;
  Timer? _tick;
  bool _disposed = false;

  FrameStore? get store => _store;
  GifDocument? get doc => _doc;
  int get current => _current;
  bool get playing => _playing;
  bool get opening => _opening;

  /// Decode [gifBytes] into a fresh session store and make it the document.
  /// The previous store (if any) is disposed after the swap.
  Future<void> openBytes(
    Uint8List gifBytes, {
    void Function(int decoded, int total)? onProgress,
  }) async {
    _opening = true;
    notifyListeners();
    try {
      final dir = await Directory.systemTemp.createTemp('glimpr_gif_editor');
      final store = FrameStore(dir);
      try {
        final doc = await importGif(gifBytes, store, onProgress: onProgress);
        final old = _store;
        _stopTicker();
        _store = store;
        _doc = doc;
        _current = 0;
        _playing = false;
        unawaited(old?.dispose());
      } catch (_) {
        unawaited(store.dispose());
        rethrow;
      }
    } finally {
      _opening = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Jump to frame [i] (clamped). Playback, if running, continues from there.
  void seek(int i) {
    final doc = _doc;
    if (doc == null || doc.frames.isEmpty) return;
    _current = i.clamp(0, doc.frameCount - 1);
    if (_playing) {
      _stopTicker();
      _scheduleTick();
    }
    notifyListeners();
  }

  void togglePlay() {
    final doc = _doc;
    if (doc == null || doc.frames.isEmpty) return;
    _playing = !_playing;
    if (_playing) {
      _scheduleTick();
    } else {
      _stopTicker();
    }
    notifyListeners();
  }

  void pause() {
    if (!_playing) return;
    _playing = false;
    _stopTicker();
    notifyListeners();
  }

  /// Self-rescheduling tick honoring EACH frame's own delay (a fixed-rate
  /// ticker would drift against variable-delay GIFs).
  void _scheduleTick() {
    final doc = _doc;
    if (doc == null) return;
    _tick = Timer(Duration(milliseconds: doc.frames[_current].delayMs), () {
      if (_disposed || !_playing) return;
      _current = (_current + 1) % doc.frameCount;
      notifyListeners();
      _scheduleTick();
    });
  }

  void _stopTicker() {
    _tick?.cancel();
    _tick = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _stopTicker();
    unawaited(_store?.dispose());
    super.dispose();
  }
}
