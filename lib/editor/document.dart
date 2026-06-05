import 'dart:ui' as ui;
import 'package:flutter/widgets.dart' show Size;
import 'drawable.dart';

/// One undo snapshot: the drawable list plus the (editor-only) canvas image +
/// size. The capture overlay never trims, so its snapshots always carry a null
/// canvas and behave exactly as a plain drawable list.
class _Snapshot {
  final List<Drawable> drawables;
  final ui.Image? canvasImage;
  final Size? canvasSize;
  const _Snapshot(this.drawables, this.canvasImage, this.canvasSize);
}

/// Immutable editor state with snapshot-based undo/redo. Every mutating method
/// returns a new document; the current snapshot is the last entry in [_past].
///
/// Each snapshot also carries an OPTIONAL canvas (image + size) so the image
/// editor's destructive crop-trim is undoable together with the annotations.
/// Drawable-only edits inherit the current canvas; the capture overlay never
/// sets one, so [canvasImage]/[canvasSize] stay null and the drawable path is
/// byte-for-byte unchanged for it.
class EditorDocument {
  final List<_Snapshot> _past; // history incl. current at last index
  final List<_Snapshot> _future;

  const EditorDocument._(this._past, this._future);
  const EditorDocument()
      : _past = const [_Snapshot(<Drawable>[], null, null)],
        _future = const [];

  List<Drawable> get drawables => _past.last.drawables;

  /// The current canvas image, or null when the host's base image is unmodified
  /// (always null for the capture overlay).
  ui.Image? get canvasImage => _past.last.canvasImage;

  /// The current canvas logical size, or null when unmodified.
  Size? get canvasSize => _past.last.canvasSize;

  bool get canUndo => _past.length > 1;
  bool get canRedo => _future.isNotEmpty;

  /// Push a new snapshot with [next] drawables, keeping the current canvas.
  EditorDocument _commit(List<Drawable> next) {
    final cur = _past.last;
    return EditorDocument._(
        [..._past, _Snapshot(next, cur.canvasImage, cur.canvasSize)], const []);
  }

  EditorDocument add(Drawable d) => _commit([...drawables, d]);

  EditorDocument replaceAt(int i, Drawable d) {
    final next = [...drawables]..[i] = d;
    return _commit(next);
  }

  EditorDocument removeAt(int i) {
    final next = [...drawables]..removeAt(i);
    return _commit(next);
  }

  /// Replace [i] in the CURRENT state WITHOUT creating an undo step. For async
  /// cosmetic backfills (e.g. a pixelate mosaic finishing after the region was
  /// already committed) that must not become a separate undo entry.
  EditorDocument replaceAtSilent(int i, Drawable d) {
    final cur = _past.last;
    if (i < 0 || i >= cur.drawables.length) return this;
    final next = [...cur.drawables]..[i] = d;
    final past = [..._past]
      ..[_past.length - 1] = _Snapshot(next, cur.canvasImage, cur.canvasSize);
    return EditorDocument._(past, _future);
  }

  /// Destructive crop-trim (image editor only): push a snapshot carrying the new
  /// (already-shifted) [drawables] AND the cropped [image] + [size]. Undo
  /// restores the previous snapshot's drawables + canvas (null = the host base
  /// image), so the original pixels return without a deep clone.
  EditorDocument trimmed(List<Drawable> drawables, ui.Image image, Size size) =>
      EditorDocument._([..._past, _Snapshot(drawables, image, size)], const []);

  EditorDocument undo() {
    if (!canUndo) return this;
    final past = [..._past];
    final popped = past.removeLast();
    return EditorDocument._(past, [popped, ..._future]);
  }

  EditorDocument redo() {
    if (!canRedo) return this;
    final future = [..._future];
    final next = future.removeAt(0);
    return EditorDocument._([..._past, next], future);
  }
}
