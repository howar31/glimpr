import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/overlay/session_op_log.dart';

void main() {
  group('SessionOpLog', () {
    test('clocks are monotonic across displays', () {
      final log = SessionOpLog();
      expect(log.nextClock(), 1);
      log.recordOp(1, 10);
      expect(log.nextClock(), 2);
      log.recordOp(5, 20); // remote assigned a higher clock
      expect(log.nextClock(), 6);
    });

    test('undo targets the latest applied op regardless of display', () {
      final log = SessionOpLog();
      log.recordOp(1, 10);
      log.recordOp(2, 20);
      expect(log.undoTarget, (clock: 2, display: 20));
      expect(log.markUndone(2, 20), isTrue);
      expect(log.undoTarget, (clock: 1, display: 10));
      expect(log.redoTarget, (clock: 2, display: 20));
    });

    test('redo re-applies the most recently undone op', () {
      final log = SessionOpLog();
      log.recordOp(1, 10);
      log.recordOp(2, 20);
      log.markUndone(2, 20);
      log.markUndone(1, 10);
      expect(log.redoTarget, (clock: 1, display: 10));
      expect(log.markRedone(1, 10), isTrue);
      expect(log.undoTarget, (clock: 1, display: 10));
      expect(log.redoTarget, (clock: 2, display: 20));
    });

    test('a new op kills the redo tail', () {
      final log = SessionOpLog();
      log.recordOp(1, 10);
      log.markUndone(1, 10);
      expect(log.redoTarget, isNotNull);
      log.recordOp(2, 20);
      expect(log.redoTarget, isNull);
      expect(log.undoTarget, (clock: 2, display: 20));
    });

    test('desynced marks are rejected without mutating the log', () {
      final log = SessionOpLog();
      log.recordOp(1, 10);
      expect(log.markUndone(9, 10), isFalse); // wrong clock
      expect(log.markUndone(1, 99), isFalse); // wrong display
      expect(log.undoTarget, (clock: 1, display: 10));
      expect(log.markRedone(1, 10), isFalse); // nothing undone yet
      log.markUndone(1, 10);
      expect(log.markRedone(9, 10), isFalse);
      expect(log.redoTarget, (clock: 1, display: 10));
    });

    test('empty log: no targets, marks rejected; clear resets the clock', () {
      final log = SessionOpLog();
      expect(log.undoTarget, isNull);
      expect(log.redoTarget, isNull);
      expect(log.markUndone(1, 10), isFalse);
      expect(log.isEmpty, isTrue);
      log.recordOp(3, 10);
      log.clear();
      expect(log.isEmpty, isTrue);
      expect(log.nextClock(), 1);
    });
  });
}
