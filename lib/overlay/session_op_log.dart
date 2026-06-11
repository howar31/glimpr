/// Session-wide undo/redo ordering for the multi-display capture overlay.
///
/// Every display's engine holds its OWN document (drawables never cross
/// displays), but a capture session reads as one work surface — so ⌘Z must
/// undo the session's latest op no matter which display it landed on. Each
/// engine keeps an identical replica of this log: local commits assign the
/// next logical clock and broadcast {op, display}; undo/redo broadcast the
/// (clock, display) they target, every replica moves the entry between the
/// applied/undone stacks, and only the OWNING display touches its document.
/// Single user -> commits are serial in human time; the desync guards below
/// make a lost/late message degrade to a no-op instead of a wrong undo.
class SessionOpLog {
  final List<({int clock, int display})> _applied = [];
  final List<({int clock, int display})> _undone = [];
  int _maxClock = 0;

  /// The clock for a NEW local op (monotonic across the session, regardless
  /// of which display assigned the previous one).
  int nextClock() => _maxClock + 1;

  /// Record a committed op (local or remote). A new op kills the redo tail,
  /// mirroring EditorDocument's commit semantics.
  void recordOp(int clock, int display) {
    if (clock > _maxClock) _maxClock = clock;
    _applied.add((clock: clock, display: display));
    _undone.clear();
  }

  /// The session's most recent applied op — what ⌘Z anywhere should undo.
  ({int clock, int display})? get undoTarget =>
      _applied.isEmpty ? null : _applied.last;

  /// The most recently undone op — what ⇧⌘Z anywhere should re-apply.
  ({int clock, int display})? get redoTarget =>
      _undone.isEmpty ? null : _undone.last;

  /// Move (clock, display) from applied to undone. False (and no change) when
  /// it is not the current undo target — a desynced replica must not undo
  /// the wrong op.
  bool markUndone(int clock, int display) {
    final t = undoTarget;
    if (t == null || t.clock != clock || t.display != display) return false;
    _applied.removeLast();
    _undone.add(t);
    return true;
  }

  /// Move (clock, display) from undone back to applied. Same guard as
  /// [markUndone].
  bool markRedone(int clock, int display) {
    final t = redoTarget;
    if (t == null || t.clock != clock || t.display != display) return false;
    _undone.removeLast();
    _applied.add(t);
    return true;
  }

  bool get isEmpty => _applied.isEmpty && _undone.isEmpty;

  /// New capture session: forget everything.
  void clear() {
    _applied.clear();
    _undone.clear();
    _maxClock = 0;
  }
}
