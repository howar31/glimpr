import 'dart:io' show Platform;
import 'dart:math' show Random;

/// strftime-style `%`-token engine, shared by the filename template and the
/// output subfolder pattern (single source of truth: [kNameTokens] drives the
/// parser, the Settings picker, and the docs, so they never drift).
///
/// Two render modes:
///   - [NameMode.filename] strips ALL path separators (a filename can't span
///     folders), sanitises illegal characters, and falls back to a built-in
///     name when the result is empty.
///   - [NameMode.path] keeps separators as folder boundaries, accepts both `/`
///     and `\` and normalises them to the current OS separator, drops `..` and
///     empty segments, and can never produce an absolute path.

enum NameMode { filename, path }

enum TokenCategory { dateTime, content, counter, random, computer }

/// One row of the token table. [example] is a static sample shown in the picker;
/// the human description is resolved in the UI (keeps this file Flutter-free).
class NameToken {
  final String token; // includes the leading '%', e.g. '%Y'
  final TokenCategory category;
  final String example;
  final bool takesCount; // %i / %ra / %rn / %rx accept a trailing digit count

  const NameToken(this.token, this.category, this.example,
      {this.takesCount = false});

  /// The body without the leading '%'.
  String get body => token.substring(1);
}

/// The single source of truth for every supported token.
const List<NameToken> kNameTokens = [
  // Date & time (strftime; filename-safe — no colon/locale composites).
  NameToken('%Y', TokenCategory.dateTime, '2026'),
  NameToken('%y', TokenCategory.dateTime, '26'),
  NameToken('%m', TokenCategory.dateTime, '06'),
  NameToken('%d', TokenCategory.dateTime, '14'),
  NameToken('%H', TokenCategory.dateTime, '22'),
  NameToken('%I', TokenCategory.dateTime, '10'),
  NameToken('%M', TokenCategory.dateTime, '30'),
  NameToken('%S', TokenCategory.dateTime, '05'),
  NameToken('%p', TokenCategory.dateTime, 'PM'),
  NameToken('%j', TokenCategory.dateTime, '165'),
  NameToken('%V', TokenCategory.dateTime, '24'),
  NameToken('%a', TokenCategory.dateTime, 'Sat'),
  NameToken('%A', TokenCategory.dateTime, 'Saturday'),
  NameToken('%b', TokenCategory.dateTime, 'Jun'),
  NameToken('%B', TokenCategory.dateTime, 'June'),
  NameToken('%s', TokenCategory.dateTime, '1781000000'),
  // Content.
  NameToken('%title', TokenCategory.content, 'Safari'),
  NameToken('%app', TokenCategory.content, 'Safari'),
  // Counter.
  NameToken('%i', TokenCategory.counter, '0042', takesCount: true),
  // Random.
  NameToken('%ra', TokenCategory.random, 'a1b2c3', takesCount: true),
  NameToken('%rn', TokenCategory.random, '482915', takesCount: true),
  NameToken('%rx', TokenCategory.random, '7f3a2c', takesCount: true),
  NameToken('%guid', TokenCategory.random, '3f2504e0-4f89-41d3-9a0c-0305e82c3301'),
  // Computer.
  NameToken('%host', TokenCategory.computer, 'MacBook-Pro'),
  NameToken('%user', TokenCategory.computer, 'howard'),
];

/// Token bodies sorted longest-first, so the parser matches multi-letter tokens
/// (title, app, guid, host, user, ra, rn, rx) before single strftime letters.
final List<String> _bodiesByLength = () {
  final bodies = kNameTokens.map((t) => t.body).toList();
  bodies.sort((a, b) => b.length.compareTo(a.length));
  return bodies;
}();

const Set<String> _takesCount = {'i', 'ra', 'rn', 'rx'};

/// Everything the resolvers need; injectable for tests and a stable preview.
class NameContext {
  final DateTime now;
  final String windowTitle;
  final String appName;
  final int counter;

  /// Returns a value in [0, n). Injectable so tests/preview are deterministic.
  final int Function(int n) rand;

  NameContext({
    required this.now,
    this.windowTitle = '',
    this.appName = '',
    this.counter = 0,
    int Function(int n)? rand,
  }) : rand = rand ?? _defaultRand;

  String get titleOrApp => windowTitle.isNotEmpty ? windowTitle : appName;

  static final Random _rng = Random();
  static int _defaultRand(int n) => _rng.nextInt(n);
}

/// Renders [pattern] for [ctx] in the given [mode].
String renderPattern(String pattern, NameContext ctx, NameMode mode) {
  final out = StringBuffer();
  var i = 0;
  while (i < pattern.length) {
    final ch = pattern[i];
    if (ch != '%') {
      out.write(ch);
      i++;
      continue;
    }
    // A '%'. Escape first.
    if (i + 1 < pattern.length && pattern[i + 1] == '%') {
      out.write('%');
      i += 2;
      continue;
    }
    final body = _matchBody(pattern, i + 1);
    if (body == null) {
      // Unknown token: keep the '%' verbatim, resume at the next character.
      out.write('%');
      i++;
      continue;
    }
    var j = i + 1 + body.length;
    int? count;
    if (_takesCount.contains(body)) {
      final start = j;
      while (j < pattern.length && _isDigit(pattern.codeUnitAt(j))) {
        j++;
      }
      if (j > start) count = int.parse(pattern.substring(start, j));
    }
    // Token VALUES never introduce structural separators (a window title with a
    // slash must not fragment the folder tree) — sanitise the value in both
    // modes; only PATTERN-literal separators are structural (handled in finish).
    var val = _sanitizeValue(_resolve(body, count, ctx));
    if ((body == 'title' || body == 'app') && val.length > 50) {
      val = val.substring(0, 50).trim();
    }
    out.write(val);
    i = j;
  }
  final raw = out.toString();
  return mode == NameMode.filename ? _finishFilename(raw, ctx) : _finishPath(raw);
}

/// True when [pattern] contains the `%i` counter token (used to gate the
/// persistent counter's increment — never advance it silently).
bool patternUsesCounter(String pattern) {
  var i = 0;
  while (i < pattern.length) {
    if (pattern[i] != '%') {
      i++;
      continue;
    }
    if (i + 1 < pattern.length && pattern[i + 1] == '%') {
      i += 2;
      continue;
    }
    final body = _matchBody(pattern, i + 1);
    if (body == null) {
      i++;
      continue;
    }
    if (body == 'i') return true;
    i += 1 + body.length;
  }
  return false;
}

// --- parsing helpers -------------------------------------------------------

String? _matchBody(String pattern, int at) {
  for (final body in _bodiesByLength) {
    if (pattern.startsWith(body, at)) return body;
  }
  return null;
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

// --- resolvers -------------------------------------------------------------

const _weekdayShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _weekdayFull = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'
];
const _monthShort = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
];
const _monthFull = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December'
];

String _pad(int n, int width) => n.toString().padLeft(width, '0');

String _resolve(String body, int? count, NameContext ctx) {
  final t = ctx.now;
  switch (body) {
    case 'Y':
      return _pad(t.year, 4);
    case 'y':
      return _pad(t.year % 100, 2);
    case 'm':
      return _pad(t.month, 2);
    case 'd':
      return _pad(t.day, 2);
    case 'H':
      return _pad(t.hour, 2);
    case 'I':
      final h12 = t.hour % 12 == 0 ? 12 : t.hour % 12;
      return _pad(h12, 2);
    case 'M':
      return _pad(t.minute, 2);
    case 'S':
      return _pad(t.second, 2);
    case 'p':
      return t.hour < 12 ? 'AM' : 'PM';
    case 'j':
      final doy = t.difference(DateTime(t.year, 1, 1)).inDays + 1;
      return _pad(doy, 3);
    case 'V':
      return _pad(_isoWeek(t), 2);
    case 'a':
      return _weekdayShort[t.weekday - 1];
    case 'A':
      return _weekdayFull[t.weekday - 1];
    case 'b':
      return _monthShort[t.month - 1];
    case 'B':
      return _monthFull[t.month - 1];
    case 's':
      return (t.millisecondsSinceEpoch ~/ 1000).toString();
    case 'title':
      return ctx.titleOrApp;
    case 'app':
      return ctx.appName;
    case 'i':
      return count == null ? ctx.counter.toString() : _pad(ctx.counter, count);
    case 'ra':
      return _randStr(_alnum, count ?? 6, ctx.rand);
    case 'rn':
      return _randStr(_digits, count ?? 6, ctx.rand);
    case 'rx':
      return _randStr(_hex, count ?? 6, ctx.rand);
    case 'guid':
      return _guidV4(ctx.rand);
    case 'host':
      return Platform.localHostname;
    case 'user':
      return Platform.environment['USER'] ??
          Platform.environment['USERNAME'] ??
          '';
  }
  return '';
}

/// ISO-8601 week number (weeks start Monday; week 1 contains the first Thursday).
int _isoWeek(DateTime t) {
  final date = DateTime(t.year, t.month, t.day);
  final thursday = date.add(Duration(days: 4 - (date.weekday)));
  final firstJan = DateTime(thursday.year, 1, 1);
  return ((thursday.difference(firstJan).inDays) / 7).floor() + 1;
}

const _alnum =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
const _digits = '0123456789';
const _hex = '0123456789abcdef';

String _randStr(String charset, int len, int Function(int) rand) {
  if (len <= 0) return '';
  final sb = StringBuffer();
  for (var k = 0; k < len; k++) {
    sb.write(charset[rand(charset.length)]);
  }
  return sb.toString();
}

/// Random v4 UUID (lowercase, hyphenated — all characters are filename-safe).
String _guidV4(int Function(int) rand) {
  final h = List<String>.generate(32, (_) => _hex[rand(16)]);
  h[12] = '4'; // version
  h[16] = _hex[8 + rand(4)]; // variant 8-b
  final j = h.join();
  return '${j.substring(0, 8)}-${j.substring(8, 12)}-${j.substring(12, 16)}'
      '-${j.substring(16, 20)}-${j.substring(20)}';
}

// --- sanitisation / finishing ----------------------------------------------

final _illegal = RegExp(r'[/\\:*?"<>|\x00-\x1f]');
final _separators = RegExp(r'[/\\]');
final _ws = RegExp(r'\s+');

/// Strip filesystem-reserved characters (including separators) from a single
/// token value, collapse whitespace. Used for every token value in both modes.
String _sanitizeValue(String s) {
  s = s.replaceAll(_illegal, '');
  s = s.replaceAll(_ws, ' ').trim();
  return s;
}

String _finishFilename(String raw, NameContext ctx) {
  var s = raw.replaceAll(_illegal, ''); // also removes any literal separators
  s = s.replaceAll(RegExp(r'__+'), '_');
  s = s.replaceAll(RegExp(r'\s{2,}'), ' ');
  s = s.replaceAll(RegExp(r'^[_\-\s]+|[_\-\s]+$'), '').trim();
  if (s.isEmpty) {
    final d = '${_pad(ctx.now.year, 4)}-${_pad(ctx.now.month, 2)}-'
        '${_pad(ctx.now.day, 2)}';
    final tm = '${_pad(ctx.now.hour, 2)}-${_pad(ctx.now.minute, 2)}-'
        '${_pad(ctx.now.second, 2)}';
    return 'Screenshot_${d}_$tm';
  }
  return s;
}

/// Joins the rendered subfolder as a RELATIVE path under the save dir: split on
/// either separator, sanitise + cap each segment, drop empty / `..`, and rejoin
/// with the current OS separator. Never absolute (a leading separator yields an
/// empty first segment, which is dropped).
String _finishPath(String raw) {
  final segments = <String>[];
  for (var seg in raw.split(_separators)) {
    seg = seg.replaceAll(_illegal, '');
    seg = seg.replaceAll(_ws, ' ').trim();
    if (seg.length > 50) seg = seg.substring(0, 50).trim();
    if (seg.isEmpty || seg == '..' || seg == '.') continue;
    segments.add(seg);
  }
  return segments.join(Platform.pathSeparator);
}
