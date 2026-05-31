import 'drawable.dart';

/// Immutable editor state with snapshot-based undo/redo. Every mutating method
/// returns a new document; the current drawable list is one entry in [_past].
class EditorDocument {
  final List<List<Drawable>> _past; // history incl. current at last index
  final List<List<Drawable>> _future;

  const EditorDocument._(this._past, this._future);
  const EditorDocument() : _past = const [<Drawable>[]], _future = const [];

  List<Drawable> get drawables => _past.last;
  bool get canUndo => _past.length > 1;
  bool get canRedo => _future.isNotEmpty;

  EditorDocument _commit(List<Drawable> next) =>
      EditorDocument._([..._past, next], const []);

  EditorDocument add(Drawable d) => _commit([...drawables, d]);

  EditorDocument replaceAt(int i, Drawable d) {
    final next = [...drawables]..[i] = d;
    return _commit(next);
  }

  EditorDocument removeAt(int i) {
    final next = [...drawables]..removeAt(i);
    return _commit(next);
  }

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
