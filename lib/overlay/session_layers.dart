/// LIFO stack of SUSPENDED capture layers. The LIVE layer is not stored here;
/// [capacity] counts TOTAL layers including the live one, so at most
/// [capacity] - 1 layers can be suspended.
///
/// Full-stack policy (owner decision 2026-06-12): at capacity >= 2 a new
/// trigger still stacks the live layer and the OLDEST suspended layer is
/// dropped instead ([dropOldest]) — the stack always holds the MOST RECENT
/// layers, like any history buffer, and a trigger never destroys current
/// work. Capacity 1 has nothing suspended to drop, so the live layer is
/// replaced — the pre-stack behavior.
class LayerStack<T> {
  LayerStack(this.capacity);

  /// Total layer budget for the session (re-read from Settings per capture).
  int capacity;

  final List<T> _suspended = [];

  int get suspendedCount => _suspended.length;
  bool get canSuspend => _suspended.length < capacity - 1;

  void suspend(T layer) {
    assert(canSuspend, 'suspend() called on a full LayerStack');
    _suspended.add(layer);
  }

  T? resume() => _suspended.isEmpty ? null : _suspended.removeLast();

  /// Evict the OLDEST suspended layer (the stack bottom) to make room;
  /// null when nothing is suspended. The caller disposes the returned layer.
  T? dropOldest() => _suspended.isEmpty ? null : _suspended.removeAt(0);

  /// Empty the stack, returning what was suspended (callers dispose).
  List<T> drain() {
    final all = List<T>.of(_suspended);
    _suspended.clear();
    return all;
  }
}
