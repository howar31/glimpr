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

  // Timeline selection (indices into doc.frames) + the shift-range anchor.
  // Selection is UI state, not document state: changing it never touches the
  // undo history, but mementos capture it so undo restores the full picture.
  final Set<int> _selection = {};
  int? _selAnchor;

  static const int _undoCap = 100;
  final List<_Memento> _undoStack = [];
  final List<_Memento> _redoStack = [];

  FrameStore? get store => _store;
  GifDocument? get doc => _doc;
  int get current => _current;
  bool get playing => _playing;
  bool get opening => _opening;
  Set<int> get selection => Set.unmodifiable(_selection);
  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

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
        _selection.clear();
        _selAnchor = null;
        _undoStack.clear();
        _redoStack.clear();
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

  /// Drop the document and return to the no-document (landing) state. The
  /// store is disposed asynchronously.
  void close() {
    _stopTicker();
    _playing = false;
    _current = 0;
    _selection.clear();
    _selAnchor = null;
    _undoStack.clear();
    _redoStack.clear();
    final old = _store;
    _store = null;
    _doc = null;
    unawaited(old?.dispose());
    notifyListeners();
  }

  // --- selection ----------------------------------------------------------

  /// Select frame [i]: plain click replaces the selection and re-anchors,
  /// [toggle] flips membership (cmd/ctrl-click), [range] replaces with the
  /// anchor..i span (shift-click). Selection never enters the undo history.
  void select(int i, {bool toggle = false, bool range = false}) {
    final doc = _doc;
    if (doc == null || i < 0 || i >= doc.frameCount) return;
    if (range) {
      final a = _selAnchor ?? _current;
      _selection
        ..clear()
        ..addAll([
          for (var k = a <= i ? a : i; k <= (a <= i ? i : a); k++) k,
        ]);
    } else if (toggle) {
      if (!_selection.remove(i)) _selection.add(i);
      _selAnchor = i;
    } else {
      _selection
        ..clear()
        ..add(i);
      _selAnchor = i;
    }
    notifyListeners();
  }

  void selectAll() {
    final doc = _doc;
    if (doc == null) return;
    _selection
      ..clear()
      ..addAll(List.generate(doc.frameCount, (i) => i));
    notifyListeners();
  }

  void clearSelection() {
    if (_selection.isEmpty) return;
    _selection.clear();
    _selAnchor = null;
    notifyListeners();
  }

  // --- undo/redo ----------------------------------------------------------

  /// Snapshot the mutable document state BEFORE a mutation. Frame pixels
  /// stay in the store (frames are immutable value objects), so a memento is
  /// just the list + metadata — cheap enough for every operation.
  void _pushUndo() {
    final doc = _doc!;
    _undoStack.add(_Memento(
      frames: List.of(doc.frames),
      loopCount: doc.loopCount,
      selection: Set.of(_selection),
      current: _current,
    ));
    if (_undoStack.length > _undoCap) _undoStack.removeAt(0);
    _redoStack.clear();
  }

  _Memento _snapshot() => _Memento(
        frames: List.of(_doc!.frames),
        loopCount: _doc!.loopCount,
        selection: Set.of(_selection),
        current: _current,
      );

  void _restore(_Memento m) {
    _doc = GifDocument(frames: m.frames, loopCount: m.loopCount);
    _selection
      ..clear()
      ..addAll(m.selection);
    _current = m.current.clamp(0, m.frames.length - 1);
    notifyListeners();
  }

  void undo() {
    if (_undoStack.isEmpty) return;
    pause();
    _redoStack.add(_snapshot());
    _restore(_undoStack.removeLast());
  }

  void redo() {
    if (_redoStack.isEmpty) return;
    pause();
    _undoStack.add(_snapshot());
    _restore(_redoStack.removeLast());
  }

  // --- frame operations ---------------------------------------------------

  /// Delete the selected frames. Refused when nothing is selected or the
  /// selection covers every frame (a document always keeps one frame). The
  /// playhead and selection collapse onto the frame that now occupies the
  /// first deleted slot.
  void deleteSelected() {
    final doc = _doc;
    if (doc == null || _selection.isEmpty) return;
    if (_selection.length >= doc.frameCount) return;
    pause();
    _pushUndo();
    final first = _selection.reduce((a, b) => a < b ? a : b);
    final kept = <GifFrame>[
      for (var i = 0; i < doc.frameCount; i++)
        if (!_selection.contains(i)) doc.frames[i],
    ];
    _doc = GifDocument(frames: kept, loopCount: doc.loopCount);
    final landing = first.clamp(0, kept.length - 1);
    _selection
      ..clear()
      ..add(landing);
    _selAnchor = landing;
    _current = landing;
    notifyListeners();
  }

  /// Move every selected frame one slot left (-1) or right (+1). Frames
  /// process from the receiving edge so a block shifts as one unit; a frame
  /// against the edge (or against a blocked selected neighbor) stays put.
  /// A move where nothing shifts leaves no undo entry.
  void moveSelected(int delta) {
    assert(delta == -1 || delta == 1);
    final doc = _doc;
    if (doc == null || _selection.isEmpty) return;
    final frames = List.of(doc.frames);
    final order = _selection.toList()
      ..sort((a, b) => delta < 0 ? a - b : b - a);
    final moved = <int>{};
    var changed = false;
    for (final i in order) {
      final target = i + delta;
      if (target < 0 || target >= frames.length || moved.contains(target)) {
        moved.add(i); // blocked: occupies its old slot, may block the next
        continue;
      }
      final tmp = frames[target];
      frames[target] = frames[i];
      frames[i] = tmp;
      moved.add(target);
      changed = true;
    }
    if (!changed) return;
    pause();
    _pushUndo();
    _doc = GifDocument(frames: frames, loopCount: doc.loopCount);
    _selection
      ..clear()
      ..addAll(moved);
    notifyListeners();
  }

  /// Reverse the frame contents at the selected positions (two or more),
  /// or the whole document when the selection is empty or a single frame.
  void reverse() {
    final doc = _doc;
    if (doc == null || doc.frameCount < 2) return;
    pause();
    _pushUndo();
    final frames = List.of(doc.frames);
    if (_selection.length >= 2) {
      final pos = _selection.toList()..sort();
      for (var a = 0, b = pos.length - 1; a < b; a++, b--) {
        final tmp = frames[pos[a]];
        frames[pos[a]] = frames[pos[b]];
        frames[pos[b]] = tmp;
      }
    } else {
      frames.setAll(0, frames.reversed.toList());
    }
    _doc = GifDocument(frames: frames, loopCount: doc.loopCount);
    notifyListeners();
  }

  /// Collapse runs of consecutive identical frames (store content hash);
  /// the run's first frame survives and absorbs the removed delays.
  void removeDuplicates() {
    final doc = _doc;
    final store = _store;
    if (doc == null || store == null || doc.frameCount < 2) return;
    final kept = <GifFrame>[doc.frames.first];
    var changed = false;
    for (var i = 1; i < doc.frameCount; i++) {
      final f = doc.frames[i];
      final last = kept.last;
      if (store.hashFor(f.key) == store.hashFor(last.key) &&
          f.width == last.width &&
          f.height == last.height) {
        kept[kept.length - 1] = last.withDelay(last.delayMs + f.delayMs);
        changed = true;
      } else {
        kept.add(f);
      }
    }
    if (!changed) return;
    pause();
    _pushUndo();
    _doc = GifDocument(frames: kept, loopCount: doc.loopCount);
    _selection.clear();
    _selAnchor = null;
    _current = _current.clamp(0, kept.length - 1);
    notifyListeners();
  }

  /// Keep the first frame of every [keepEvery]-sized group; the removed
  /// frames' delays merge into their group's survivor, so the total
  /// duration is preserved while the frame rate drops.
  void reduceFrames(int keepEvery) {
    assert(keepEvery >= 2);
    final doc = _doc;
    if (doc == null || doc.frameCount < 2) return;
    pause();
    _pushUndo();
    final kept = <GifFrame>[];
    for (var i = 0; i < doc.frameCount; i += keepEvery) {
      var delay = doc.frames[i].delayMs;
      for (var k = i + 1; k < i + keepEvery && k < doc.frameCount; k++) {
        delay += doc.frames[k].delayMs;
      }
      kept.add(doc.frames[i].withDelay(delay));
    }
    _doc = GifDocument(frames: kept, loopCount: doc.loopCount);
    _selection.clear();
    _selAnchor = null;
    _current = (_current ~/ keepEvery).clamp(0, kept.length - 1);
    notifyListeners();
  }

  /// Append the whole sequence reversed (forward-then-back playback).
  void yoyo() {
    final doc = _doc;
    if (doc == null || doc.frameCount < 2) return;
    pause();
    _pushUndo();
    _doc = GifDocument(
      frames: [...doc.frames, ...doc.frames.reversed],
      loopCount: doc.loopCount,
    );
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

/// One undo/redo snapshot: the frame list is copied but the frames (and the
/// pixels behind their store keys) are shared immutable values.
class _Memento {
  const _Memento({
    required this.frames,
    required this.loopCount,
    required this.selection,
    required this.current,
  });

  final List<GifFrame> frames;
  final int loopCount;
  final Set<int> selection;
  final int current;
}
