import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/overlay/session_layers.dart';

void main() {
  test('capacity 1 never suspends', () {
    final s = LayerStack<String>(1);
    expect(s.canSuspend, isFalse);
    expect(s.suspendedCount, 0);
  });

  test('capacity 3 holds two suspended layers then refuses', () {
    final s = LayerStack<String>(3);
    expect(s.canSuspend, isTrue);
    s.suspend('a');
    expect(s.canSuspend, isTrue);
    s.suspend('b');
    expect(s.canSuspend, isFalse);
    expect(s.suspendedCount, 2);
  });

  test('resume is LIFO and empties down to null', () {
    final s = LayerStack<String>(3);
    s.suspend('a');
    s.suspend('b');
    expect(s.resume(), 'b');
    expect(s.resume(), 'a');
    expect(s.resume(), isNull);
  });

  test('dropOldest evicts from the bottom in FIFO order', () {
    final s = LayerStack<String>(3);
    expect(s.dropOldest(), isNull);
    s.suspend('a');
    s.suspend('b');
    expect(s.dropOldest(), 'a'); // oldest first
    expect(s.canSuspend, isTrue); // room again
    s.suspend('c');
    expect(s.resume(), 'c'); // LIFO resume unaffected
    expect(s.resume(), 'b');
    expect(s.resume(), isNull);
  });

  test('drain returns all suspended layers and clears', () {
    final s = LayerStack<String>(5);
    s.suspend('a');
    s.suspend('b');
    expect(s.drain(), ['a', 'b']);
    expect(s.suspendedCount, 0);
    expect(s.resume(), isNull);
  });
}
