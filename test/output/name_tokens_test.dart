import 'dart:io' show Platform;
import 'package:flutter_test/flutter_test.dart';
import 'package:glimpr/output/name_tokens.dart';

void main() {
  // Local DateTime (matches the real app's DateTime.now()): Sun 14 Jun 2026.
  final fixed = DateTime(2026, 6, 14, 22, 30, 5);
  final sep = Platform.pathSeparator;

  NameContext ctx({
    String title = '',
    String app = '',
    int counter = 0,
    int Function(int)? rand,
  }) =>
      NameContext(
        now: fixed,
        windowTitle: title,
        appName: app,
        counter: counter,
        rand: rand ?? (n) => 0,
      );

  String fn(String p, {NameContext? c}) =>
      renderPattern(p, c ?? ctx(), NameMode.filename);
  String path(String p, {NameContext? c}) =>
      renderPattern(p, c ?? ctx(), NameMode.path);

  group('date/time tokens', () {
    test('numeric fields', () {
      expect(fn('%Y'), '2026');
      expect(fn('%y'), '26');
      expect(fn('%m'), '06');
      expect(fn('%d'), '14');
      expect(fn('%H'), '22');
      expect(fn('%I'), '10');
      expect(fn('%M'), '30');
      expect(fn('%S'), '05');
      expect(fn('%p'), 'PM');
      expect(fn('%j'), '165');
      expect(fn('%V'), '24');
    });

    test('names are locale-free English', () {
      expect(fn('%a'), 'Sun');
      expect(fn('%A'), 'Sunday');
      expect(fn('%b'), 'Jun');
      expect(fn('%B'), 'June');
    });

    test('unix timestamp is numeric', () {
      expect(fn('%s'), matches(RegExp(r'^\d+$')));
    });

    test('composite date pattern', () {
      expect(fn('%Y-%m-%d_%H-%M-%S'), '2026-06-14_22-30-05');
    });
  });

  group('longest-match', () {
    test('%app resolves the app, not %a + "pp"', () {
      expect(fn('%app', c: ctx(app: 'Foo')), 'Foo');
    });
    test('%a is the weekday even when %app exists', () {
      expect(fn('%a', c: ctx(app: 'Foo')), 'Sun');
    });
    test('%title falls back to app when no title', () {
      expect(fn('%title', c: ctx(app: 'Foo')), 'Foo');
      expect(fn('%title', c: ctx(title: 'Bar', app: 'Foo')), 'Bar');
    });
    test('%ra is random, not %r + a', () {
      expect(fn('%ra3'), 'AAA'); // rand->0 picks the first alnum char 'A'
    });
  });

  group('count suffix', () {
    test('%iN zero-pads, %i does not', () {
      expect(fn('%i4', c: ctx(counter: 42)), '0042');
      expect(fn('%i', c: ctx(counter: 42)), '42');
    });
    test('random length follows the count, default 6', () {
      expect(fn('%ra6').length, 6);
      expect(fn('%ra').length, 6);
      expect(fn('%ra3').length, 3);
    });
    test('digit run stops at the next %', () {
      expect(fn('%i4%Y', c: ctx(counter: 42)), '00422026');
    });
    test('trailing non-digits stay literal', () {
      expect(fn('%i4abc', c: ctx(counter: 42)), '0042abc');
    });
  });

  group('escapes / unknown', () {
    test('%% is a literal percent', () {
      expect(fn('100%%'), '100%');
    });
    test('unknown token kept verbatim', () {
      expect(fn('%z'), '%z');
    });
  });

  group('random charsets', () {
    NameContext seq() {
      var k = 0;
      return ctx(rand: (n) => (k++) % n);
    }

    test('%rn digits, %rx hex, %ra alnum', () {
      expect(fn('%rn4', c: seq()), '0123');
      expect(fn('%rx6', c: seq()), '012345');
      expect(fn('%ra3', c: seq()), 'ABC');
    });
    test('%guid is a v4 UUID shape', () {
      expect(
        fn('%guid'),
        matches(RegExp(
            r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')),
      );
    });
  });

  group('filename mode', () {
    test('separators in a token value are stripped', () {
      expect(fn('%title', c: ctx(title: 'a/b')), 'ab');
    });
    test('illegal chars stripped', () {
      expect(fn('%title', c: ctx(title: 'a:b*c?')), 'abc');
    });
    test('empty pattern falls back to the built-in name', () {
      expect(fn(''), 'Screenshot_2026-06-14_22-30-05');
      expect(fn('%title'), 'Screenshot_2026-06-14_22-30-05'); // no title/app
    });
    test('doubled separators from an empty token are tidied', () {
      expect(fn('%title__%Y'), '2026');
    });
    test('%title/%app capped at 50 chars', () {
      final long = 'x' * 60;
      expect(fn('%title', c: ctx(title: long)).length, 50);
    });
  });

  group('path mode', () {
    test('both / and \\ normalise to the OS separator', () {
      expect(path('%Y/%m'), '2026${sep}06');
      expect(path('%Y\\%m'), '2026${sep}06');
    });
    test('consecutive separators collapse', () {
      expect(path('%Y//%m'), '2026${sep}06');
    });
    test('leading/trailing separators trimmed (never absolute)', () {
      expect(path('/%Y/%m/'), '2026${sep}06');
    });
    test('.. and . segments dropped', () {
      expect(path('%Y/../%m'), '2026${sep}06');
      expect(path('%Y/./%m'), '2026${sep}06');
    });
    test('absolute path is relativised', () {
      expect(path('/etc/%Y'), 'etc${sep}2026');
    });
    test('a token value with a separator does NOT fragment the tree', () {
      expect(path('%title', c: ctx(title: 'Foo/Bar')), 'FooBar');
    });
    test('per-segment illegal chars sanitised', () {
      expect(path('%Y/a:b'), '2026${sep}ab');
    });
    test('empty pattern yields no subfolder', () {
      expect(path(''), '');
      expect(path('%title'), ''); // no title/app
    });
    test('default subfolder pattern', () {
      expect(path('%Y-%m/%Y-%m-%d'), '2026-06${sep}2026-06-14');
    });
  });

  group('patternUsesCounter', () {
    test('detects %i (with or without count)', () {
      expect(patternUsesCounter('%i'), isTrue);
      expect(patternUsesCounter('%Y_%i4'), isTrue);
    });
    test('false without %i, and for an escaped %%i', () {
      expect(patternUsesCounter('%Y-%m-%d'), isFalse);
      expect(patternUsesCounter('100%%i'), isFalse);
    });
  });
}
