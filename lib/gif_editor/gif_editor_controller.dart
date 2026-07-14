import 'dart:async';
import 'dart:io';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';

import '../editor/drawable.dart';
import 'burn_in.dart';
import 'document_transform.dart';
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

  // Canvas transform in flight: mutators refuse while true (the transform
  // captured the document at its start; concurrent edits would be lost).
  bool _transforming = false;
  double _transformProgress = 0;
  bool get transforming => _transforming;
  double get transformProgress => _transformProgress;

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
        _clipboard.clear(); // entries reference the outgoing store
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
    _clipboard.clear();
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
    if (_undoStack.isEmpty || _transforming) return;
    pause();
    _redoStack.add(_snapshot());
    _restore(_undoStack.removeLast());
  }

  void redo() {
    if (_redoStack.isEmpty || _transforming) return;
    pause();
    _undoStack.add(_snapshot());
    _restore(_redoStack.removeLast());
  }

  // --- canvas operations (whole-document pixel transforms) -----------------

  /// Crop every frame to the given canvas rectangle (clamped; a full-frame
  /// crop is a no-op).
  Future<void> cropDoc(int x, int y, int w, int h) async {
    final doc = _doc;
    if (doc == null) return;
    final cw = doc.frames.first.width;
    final ch = doc.frames.first.height;
    final cx = x.clamp(0, cw - 1);
    final cy = y.clamp(0, ch - 1);
    final rw = w.clamp(1, cw - cx);
    final rh = h.clamp(1, ch - cy);
    if (cx == 0 && cy == 0 && rw == cw && rh == ch) return;
    await _applyCanvasOp(CanvasOp.crop(cx, cy, rw, rh));
  }

  /// Bilinear-resize every frame to [w] x [h] (a same-size call is a no-op).
  Future<void> resizeDoc(int w, int h) async {
    final doc = _doc;
    if (doc == null) return;
    final tw = w.clamp(1, 16384);
    final th = h.clamp(1, 16384);
    if (tw == doc.frames.first.width && th == doc.frames.first.height) {
      return;
    }
    await _applyCanvasOp(CanvasOp.resize(tw, th));
  }

  /// Mirror every frame horizontally or vertically.
  Future<void> flipDoc({required bool horizontal}) => _applyCanvasOp(
      horizontal ? const CanvasOp.flipH() : const CanvasOp.flipV());

  /// Paint an opaque border band inside every frame's edges. [width] clamps
  /// to half the short side; [argb] is 0xAARRGGBB.
  Future<void> borderDoc(int width, int argb) async {
    final doc = _doc;
    if (doc == null) return;
    final short = doc.frames.first.width < doc.frames.first.height
        ? doc.frames.first.width
        : doc.frames.first.height;
    final w = width.clamp(1, short ~/ 2);
    await _applyCanvasOp(CanvasOp.border(w, argb));
  }

  /// Rotate every frame: 1 = clockwise quarter, -1 = counter-clockwise
  /// quarter, 2 = half turn.
  Future<void> rotateDoc(int quarterTurns) async {
    assert(quarterTurns == 1 || quarterTurns == -1 || quarterTurns == 2);
    await _applyCanvasOp(switch (quarterTurns) {
      1 => const CanvasOp.rotateCw(),
      -1 => const CanvasOp.rotateCcw(),
      _ => const CanvasOp.rotate180(),
    });
  }

  // --- burn-in (annotate bake / progress bar / title frame) ----------------

  /// Burn [drawables] into the SELECTED frames (empty selection = every
  /// frame). Reuses the transforming busy state; undoable like every op.
  Future<void> bakeDrawables(List<Drawable> drawables) =>
      _runBake(drawables: drawables);

  /// Draw the playback progress bar onto every frame.
  Future<void> bakeProgressBar({Color color = kProgressBarColor}) =>
      _runBake(drawables: const [], progressBar: true, progressColor: color);

  Future<void> _runBake({
    required List<Drawable> drawables,
    bool progressBar = false,
    Color progressColor = kProgressBarColor,
  }) async {
    final doc = _doc;
    final store = _store;
    if (doc == null || store == null || _transforming) return;
    if (drawables.isEmpty && !progressBar) return;
    pause();
    _transforming = true;
    _transformProgress = 0;
    notifyListeners();
    try {
      final frames = await bakeDocument(
        doc: doc,
        store: store,
        drawables: drawables,
        range: Set.of(_selection),
        progressBar: progressBar,
        progressColor: progressColor,
        onProgress: (done, total) {
          _transformProgress = done / total;
          if (!_disposed) notifyListeners();
        },
      );
      if (!identical(_doc, doc)) return;
      _pushUndo();
      // Frame count/order unchanged: selection and playhead stay valid.
      _doc = GifDocument(frames: frames, loopCount: doc.loopCount);
    } finally {
      _transforming = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Insert a blank (opaque black) title frame BEFORE the current frame with
  /// a 1s delay, and select it so the annotate surface targets it.
  Future<void> insertTitleFrame() async {
    final doc = _doc;
    final store = _store;
    if (doc == null || store == null || _transforming) return;
    pause();
    final w = doc.frames.first.width;
    final h = doc.frames.first.height;
    final rgba = Uint8List(w * h * 4);
    for (var i = 3; i < rgba.length; i += 4) {
      rgba[i] = 255; // opaque black
    }
    final key = await store.put(rgba, w, h);
    if (!identical(_doc, doc) || _disposed) return;
    _pushUndo();
    final at = _current.clamp(0, doc.frameCount);
    _doc = GifDocument(
      frames: [
        ...doc.frames.sublist(0, at),
        GifFrame(key: key, width: w, height: h, delayMs: 1000),
        ...doc.frames.sublist(at),
      ],
      loopCount: doc.loopCount,
    );
    _selection
      ..clear()
      ..add(at);
    _selAnchor = at;
    _current = at;
    notifyListeners();
  }

  Future<void> _applyCanvasOp(CanvasOp op) async {
    final doc = _doc;
    final store = _store;
    if (doc == null || store == null || _transforming) return;
    pause();
    _transforming = true;
    _transformProgress = 0;
    notifyListeners();
    try {
      final frames = await transformDocument(
        doc: doc,
        store: store,
        op: op,
        onProgress: (done, total) {
          _transformProgress = done / total;
          if (!_disposed) notifyListeners();
        },
      );
      // The document swapped under the transform (new file opened, window
      // went home): the result belongs to a dead document — discard it.
      if (!identical(_doc, doc)) return;
      _pushUndo();
      _doc = GifDocument(frames: frames, loopCount: doc.loopCount);
      _selection.clear();
      _selAnchor = null;
      _current = _current.clamp(0, frames.length - 1);
    } finally {
      _transforming = false;
      if (!_disposed) notifyListeners();
    }
  }

  // --- frame operations ---------------------------------------------------

  /// Delete the selected frames. Refused when nothing is selected or the
  /// selection covers every frame (a document always keeps one frame). The
  /// playhead and selection collapse onto the frame that now occupies the
  /// first deleted slot.
  void deleteSelected() => _removeSelection(toClipboard: false);

  /// Delete the selected frames, first placing value copies on the internal
  /// frame clipboard. Same refusal rules as [deleteSelected].
  void cutSelected() => _removeSelection(toClipboard: true);

  void _removeSelection({required bool toClipboard}) {
    final doc = _doc;
    if (doc == null || _selection.isEmpty || _transforming) return;
    if (_selection.length >= doc.frameCount) return;
    pause();
    _pushUndo();
    if (toClipboard) {
      final pos = _selection.toList()..sort();
      _clipboard
        ..clear()
        ..addAll([for (final i in pos) doc.frames[i]]);
    }
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

  // --- frame clipboard ----------------------------------------------------

  /// Internal, session-scoped: entries reference this document's frame
  /// store, so the clipboard clears whenever the store changes hands.
  final List<GifFrame> _clipboard = [];

  bool get clipboardHasFrames => _clipboard.isNotEmpty;

  /// Copy the selected frames (value copies; nothing mutates).
  void copySelected() {
    final doc = _doc;
    if (doc == null || _selection.isEmpty) return;
    final pos = _selection.toList()..sort();
    _clipboard
      ..clear()
      ..addAll([for (final i in pos) doc.frames[i]]);
    notifyListeners();
  }

  /// Insert the clipboard frames after the current frame; the pasted run
  /// becomes the selection with the playhead on its first frame.
  void pasteFrames() {
    final doc = _doc;
    if (doc == null || _clipboard.isEmpty || _transforming) return;
    pause();
    _pushUndo();
    final at = (_current + 1).clamp(0, doc.frameCount);
    final frames = [
      ...doc.frames.sublist(0, at),
      ..._clipboard,
      ...doc.frames.sublist(at),
    ];
    _doc = GifDocument(frames: frames, loopCount: doc.loopCount);
    _selection
      ..clear()
      ..addAll([for (var i = 0; i < _clipboard.length; i++) at + i]);
    _selAnchor = at;
    _current = at;
    notifyListeners();
  }

  // --- delay operations ---------------------------------------------------

  /// Set the delay of the selection (or all frames) to [ms].
  void overrideDelay(int ms) => _mapDelays((_) => ms);

  /// Add [deltaMs] (may be negative) to the selection's (or all) delays.
  void shiftDelay(int deltaMs) => _mapDelays((d) => d + deltaMs);

  /// Scale the selection's (or all) delays by [percent] (100 = unchanged).
  void scaleDelay(int percent) => _mapDelays((d) => (d * percent / 100).round());

  /// Delays clamp to a 10ms floor (the encoder floors at 2cs anyway; the
  /// model floor keeps playback math sane). No-change ops leave no history.
  void _mapDelays(int Function(int delayMs) f) {
    final doc = _doc;
    if (doc == null || _transforming) return;
    final all = _selection.isEmpty;
    var changed = false;
    final frames = <GifFrame>[];
    for (var i = 0; i < doc.frameCount; i++) {
      final frame = doc.frames[i];
      if (all || _selection.contains(i)) {
        final next = f(frame.delayMs).clamp(10, 0xFFFF * 10);
        if (next != frame.delayMs) changed = true;
        frames.add(frame.withDelay(next));
      } else {
        frames.add(frame);
      }
    }
    if (!changed) return;
    pause();
    _pushUndo();
    _doc = GifDocument(frames: frames, loopCount: doc.loopCount);
    notifyListeners();
  }

  /// Move every selected frame one slot left (-1) or right (+1). Frames
  /// process from the receiving edge so a block shifts as one unit; a frame
  /// against the edge (or against a blocked selected neighbor) stays put.
  /// A move where nothing shifts leaves no undo entry.
  void moveSelected(int delta) {
    assert(delta == -1 || delta == 1);
    final doc = _doc;
    if (doc == null || _selection.isEmpty || _transforming) return;
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
    if (doc == null || doc.frameCount < 2 || _transforming) return;
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
    if (doc == null || store == null || doc.frameCount < 2 || _transforming) {
      return;
    }
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
    if (doc == null || doc.frameCount < 2 || _transforming) return;
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
    if (doc == null || doc.frameCount < 2 || _transforming) return;
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
