import 'package:ux/src/url/chars.dart';
import 'package:ux/src/url/match.dart';
import 'package:ux/src/url/tld.dart';

/// url_detect.mm's second pass: the matches of its case-insensitive ICU
/// pattern, Patterns.WEB_URL's http, https, rtsp and ftp links with a host of
/// two or more labels or an IPv4 address, and its hosts of ASCII labels and
/// IPv4 addresses with no scheme, each ended by [webEnd] and kept where no
/// '.' glues a word to it and, with no scheme, where its host has a TLD.
List<UrlMatch> webPass(String text) {
  final out = <UrlMatch>[];
  var s = 0;
  while (s < text.length) {
    final m = _matchAt(text, s);
    if (m == null) {
      s += width(cpAt(text, s));
      continue;
    }
    final (end: matchEnd, :written) = m;
    final end = webEnd(text, s, matchEnd);
    if (!gluesWord(text, s, end) && (written || hasTld(text, s, end))) {
      final slice = text.substring(s, end);
      out.add(
        UrlMatch(
          start: s,
          end: end,
          url: written ? slice : 'http://$slice',
          kind: UrlMatchKind.web,
        ),
      );
    }
    s = matchEnd;
  }
  return out;
}

/// Whether the second pass's pattern matches all of [s] from its start.
bool matchesWhole(String s) => s.isNotEmpty && _matchAt(s, 0)?.end == s.length;

/// The pattern's match at [s], its end and whether it writes a scheme.
({int end, bool written})? _matchAt(String text, int s) {
  final c = text.codeUnitAt(s);
  if (!(isAsciiDigit(c) || isAsciiLetter(c) || c == 0x17F || c == 0x212A)) {
    return null;
  }
  if (!_startsMatch(text, s)) return null;
  final scheme = _schemeEnd(text, s);
  if (scheme != null) {
    final userinfo = _userinfoEnd(text, scheme);
    for (final h in [?userinfo, scheme]) {
      final end = _host(text, h, scheme: true);
      if (end != null) return (end: end, written: true);
    }
  }
  final end = _host(text, s, scheme: false);
  return end == null ? null : (end: end, written: false);
}

/// The pattern's start: a word boundary, or after a '_' or an unspaced
/// letter, but neither after a letter, mark or digit outside the unspaced
/// scripts and a run of 1 to 62 '_' and '-' or a '.', nor after "://".
bool _startsMatch(String text, int s) {
  if (!wordBoundary(text, s) &&
      !(s > 0 &&
          (text.codeUnitAt(s - 1) == 0x5F || isUnspaced(cpBefore(text, s))))) {
    return false;
  }
  if (s >= 2 &&
      text.codeUnitAt(s - 1) == 0x2E &&
      isSpacedLetterMarkDigit(cpBefore(text, s - 1))) {
    return false;
  }
  var run = 0;
  while (run < 63 &&
      s - run > 0 &&
      _isDashOrUnderscore(text.codeUnitAt(s - run - 1))) {
    run++;
  }
  if (run >= 1 &&
      run <= 62 &&
      s - run > 0 &&
      isSpacedLetterMarkDigit(cpBefore(text, s - run))) {
    return false;
  }
  return !(s >= 3 && text.startsWith('://', s - 3));
}

bool _isDashOrUnderscore(int c) => c == 0x5F || c == 0x2D;

/// Whether ICU's `\b` holds at [i] of [text]: never before a Grapheme_Extend
/// or Cf character, and otherwise where the character there and the one
/// before it, skipping Grapheme_Extend and Cf characters, differ in being
/// `\w`.
bool wordBoundary(String text, int i) {
  var here = false;
  if (i < text.length) {
    final cp = cpAt(text, i);
    if (isBoundaryTransparent(cp)) return false;
    here = isWord(cp);
  }
  var before = false;
  var j = i;
  while (j > 0) {
    final cp = cpBefore(text, j);
    j -= width(cp);
    if (!isBoundaryTransparent(cp)) {
      before = isWord(cp);
      break;
    }
  }
  return here != before;
}

/// Whether ICU's `$` holds at [i] of [text]: at its end, or before a line
/// terminator that ends it.
bool _textEnd(String text, int i) {
  final n = text.length;
  if (i == n) return true;
  final c = text.codeUnitAt(i);
  if (i == n - 1) {
    return (c >= 0x0A && c <= 0x0D) || c == 0x85 || c == 0x2028 || c == 0x2029;
  }
  return i == n - 2 && c == 0x0D && text.codeUnitAt(i + 1) == 0x0A;
}

/// Whether the UTF-16 unit [c] matches the lowercase ASCII letter [l] with
/// ICU's case closure, which adds U+017F to 's' and U+212A to 'k'.
bool _letterIs(int c, int l) =>
    (c | 0x20) == l && isAsciiLetter(c) ||
    (l == 0x73 && c == 0x17F) ||
    (l == 0x6B && c == 0x212A);

bool _literal(String text, int i, String word) {
  if (i + word.length > text.length) return false;
  for (var k = 0; k < word.length; k++) {
    final l = word.codeUnitAt(k);
    final c = text.codeUnitAt(i + k);
    if (isAsciiLetter(l) ? !_letterIs(c, l) : c != l) return false;
  }
  return true;
}

/// The end of `(?:https?|rtsp|ftp)://` at [s].
int? _schemeEnd(String text, int s) {
  if (_literal(text, s, 'http')) {
    final p = s + 4;
    if (p < text.length && _letterIs(text.codeUnitAt(p), 0x73)) {
      if (text.startsWith('://', p + 1)) return p + 4;
    }
    return text.startsWith('://', p) ? p + 3 : null;
  }
  for (final scheme in const ['rtsp://', 'ftp://']) {
    if (_literal(text, s, scheme)) return s + scheme.length;
  }
  return null;
}

/// Whether [c] is in `[a-z0-9$_.+!*'(),;?&=-]` with ICU's case closure.
bool _userChar(int c) =>
    isAsciiLetter(c) ||
    isAsciiDigit(c) ||
    c == 0x17F ||
    c == 0x212A ||
    "\$_.+!*'(),;?&=-".codeUnits.contains(c);

/// The end of the user part's run of characters and '%XX' escapes at [p],
/// at most [max] of them, and how many it holds.
(int, int) _userRun(String text, int p, int max) {
  var n = 0;
  while (n < max && p < text.length) {
    final c = text.codeUnitAt(p);
    if (_userChar(c)) {
      p++;
    } else if (c == 0x25 &&
        p + 2 < text.length &&
        isHex(text.codeUnitAt(p + 1)) &&
        isHex(text.codeUnitAt(p + 2))) {
      p += 3;
    } else {
      break;
    }
    n++;
  }
  return (p, n);
}

/// The end of the userinfo and its '@' at [p]: 1 to 64 characters, then
/// optionally ':' and 1 to 25 characters.
int? _userinfoEnd(String text, int p) {
  final (user, n) = _userRun(text, p, 64);
  if (n == 0 || user >= text.length) return null;
  final c = text.codeUnitAt(user);
  if (c == 0x40) return user + 1;
  if (c != 0x3A) return null;
  final (pass, m) = _userRun(text, user + 1, 25);
  if (m == 0 || pass >= text.length || text.codeUnitAt(pass) != 0x40) {
    return null;
  }
  return pass + 1;
}

/// Whether [cp] is in the pattern's UCS_CHAR set, which leaves out CJK
/// punctuation.
bool _ucs(int cp) => isUcsChar(cp) && !(cp <= 0xFFFF && isCjkPunctuation(cp));

bool _asciiAlnum(int cp) =>
    cp < 0x80 && (isAsciiLetter(cp) || isAsciiDigit(cp)) ||
    cp == 0x17F ||
    cp == 0x212A;

bool _labelEdge(int cp, bool scheme) => _asciiAlnum(cp) || scheme && _ucs(cp);

bool _labelInner(int cp, bool scheme) =>
    _labelEdge(cp, scheme) || cp == 0x2D || cp == 0x5F;

bool _tldChar(int cp, bool scheme) =>
    (cp < 0x80 && isAsciiLetter(cp)) ||
    cp == 0x17F ||
    cp == 0x212A ||
    scheme && _ucs(cp);

/// The end of the label at [p] where a '.' follows it: 1 to 63 characters
/// that a letter or digit starts and ends.
int? _label(String text, int p, bool scheme) {
  if (p >= text.length) return null;
  var cp = cpAt(text, p);
  if (!_labelEdge(cp, scheme)) return null;
  var last = cp;
  var q = p + width(cp);
  var n = 1;
  while (n < 63 && q < text.length) {
    cp = cpAt(text, q);
    if (!_labelInner(cp, scheme)) break;
    last = cp;
    q += width(cp);
    n++;
  }
  if (q < text.length &&
      text.codeUnitAt(q) == 0x2E &&
      _labelEdge(last, scheme)) {
    return q;
  }
  return null;
}

/// The match's end after a host at [p]: labels and a TLD, or an IPv4
/// address, then the pattern's port and tail, in ICU's backtracking order.
int? _host(String text, int p, {required bool scheme}) {
  final starts = <int>[];
  var at = p;
  while (true) {
    final dot = _label(text, at, scheme);
    if (dot == null) break;
    at = dot + 1;
    starts.add(at);
  }
  for (var k = starts.length - 1; k >= 0; k--) {
    for (final h in _tldEnds(text, starts[k], scheme)) {
      final end = scheme ? _portAfterScheme(text, h) : _tailBare(text, h);
      if (end != null) return end;
    }
  }
  for (final h in _ipv4Ends(text, p)) {
    final end = scheme ? _portAfterScheme(text, h) : _tailBare(text, h);
    if (end != null) return end;
  }
  return null;
}

/// The ends of a TLD at [a], longest first: `xn--` and up to 59 word
/// characters and '-' that a word character ends, then 2 to 63 letters.
Iterable<int> _tldEnds(String text, int a, bool scheme) sync* {
  final xn = scheme ? text.startsWith('xn--', a) : _literal(text, a, 'xn--');
  if (xn) {
    final run = <int>[a + 4];
    var q = a + 4;
    final word = <bool>[];
    while (run.length <= 59 && q < text.length) {
      final cp = cpAt(text, q);
      final w = scheme ? isWord(cp) : _asciiAlnum(cp);
      if (!(w || cp == 0x2D)) break;
      word.add(w);
      q += width(cp);
      run.add(q);
    }
    final r = word.length;
    for (var g = r < 58 ? r : 58; g >= 0; g--) {
      if (g < r && word[g]) yield run[g + 1];
    }
  }
  final ends = <int>[];
  var q = a;
  while (ends.length < 63 && q < text.length) {
    final cp = cpAt(text, q);
    if (!_tldChar(cp, scheme)) break;
    q += width(cp);
    ends.add(q);
  }
  for (var n = ends.length; n >= 2; n--) {
    yield ends[n - 1];
  }
}

/// The lengths of an IPv4 octet at [i], in the pattern's order: 25[0-5],
/// 2[0-4][0-9], [0-1][0-9]{2}, [1-9][0-9], then [1-9], '0' where [middle]
/// holds, or [0-9] where [last] holds.
List<int> _octets(
  String text,
  int i, {
  bool middle = false,
  bool last = false,
}) {
  int? d(int k) {
    if (i + k >= text.length) return null;
    final c = text.codeUnitAt(i + k);
    return isAsciiDigit(c) ? c - 0x30 : null;
  }

  final a = d(0), b = d(1), c = d(2);
  final out = <int>[];
  void add(int n) {
    if (out.isEmpty || out.last != n) out.add(n);
  }

  if (a == 2 && b == 5 && c != null && c <= 5) add(3);
  if (a == 2 && b != null && b <= 4 && c != null) add(3);
  if ((a == 0 || a == 1) && b != null && c != null) add(3);
  if (a != null && a >= 1 && b != null) add(2);
  if (a != null && (last || a >= 1)) add(1);
  if (middle && a == 0) add(1);
  return out;
}

/// The ends of an IPv4 address at [p], in the pattern's backtracking order.
Iterable<int> _ipv4Ends(String text, int p) sync* {
  for (final a in _octets(text, p)) {
    if (!text.startsWith('.', p + a)) continue;
    final q = p + a + 1;
    for (final b in _octets(text, q, middle: true)) {
      if (!text.startsWith('.', q + b)) continue;
      final r = q + b + 1;
      for (final c in _octets(text, r, middle: true)) {
        if (!text.startsWith('.', r + c)) continue;
        final s = r + c + 1;
        for (final d in _octets(text, s, last: true)) {
          yield s + d;
        }
      }
    }
  }
}

/// The ASCII digits of a port at [i], at most five, as their ends.
List<int> _digitEnds(String text, int i, {required bool ascii}) {
  final ends = <int>[];
  var q = i;
  while (ends.length < 5 && q < text.length) {
    final cp = cpAt(text, q);
    if (!(ascii ? cp < 0x80 && isAsciiDigit(cp) : isDigit(cp))) break;
    q += width(cp);
    ends.add(q);
  }
  return ends;
}

bool _unspacedAt(String text, int i) =>
    i < text.length && isUnspaced(cpAt(text, i));

/// After a written scheme's host at [h]: a port of ASCII digits that an
/// unspaced letter follows, or any port, then a path or a word boundary.
int? _portAfterScheme(String text, int h) {
  final colon = h < text.length && text.codeUnitAt(h) == 0x3A;
  if (colon) {
    final ends = _digitEnds(text, h + 1, ascii: true);
    for (var n = ends.length; n >= 1; n--) {
      if (_unspacedAt(text, ends[n - 1])) return ends[n - 1];
    }
    final digits = _digitEnds(text, h + 1, ascii: false);
    for (var n = digits.length; n >= 1; n--) {
      final end = _pathOrBoundary(text, digits[n - 1]);
      if (end != null) return end;
    }
  }
  return _pathOrBoundary(text, h);
}

int? _pathOrBoundary(String text, int p) {
  final path = _pathEnd(text, p);
  if (path != null) return path;
  return wordBoundary(text, p) ? p : null;
}

/// After a host with no scheme at [h]: any port, then a path, or a word
/// boundary, the text's end or an unspaced letter that '@' and an email's
/// domain do not follow.
int? _tailBare(String text, int h) {
  final ports = <int>[];
  if (h < text.length && text.codeUnitAt(h) == 0x3A) {
    final ascii = _digitEnds(text, h + 1, ascii: true);
    for (var n = ascii.length; n >= 1; n--) {
      ports.add(ascii[n - 1]);
    }
    final digits = _digitEnds(text, h + 1, ascii: false);
    for (var n = digits.length; n >= 1; n--) {
      if (wordBoundary(text, digits[n - 1])) ports.add(digits[n - 1]);
    }
  }
  ports.add(h);
  for (final p in ports) {
    final path = _pathEnd(text, p);
    if (path != null) return path;
    if ((wordBoundary(text, p) || _textEnd(text, p) || _unspacedAt(text, p)) &&
        !_emailAhead(text, p)) {
      return p;
    }
  }
  return null;
}

/// Whether `@`, a letter or digit, up to 64 letters, digits and '-', a '.'
/// and a letter or digit follow [p].
bool _emailAhead(String text, int p) {
  if (p + 1 >= text.length || text.codeUnitAt(p) != 0x40) return false;
  if (!_asciiAlnum(text.codeUnitAt(p + 1))) return false;
  var q = p + 2;
  var n = 0;
  while (n < 64 && q < text.length) {
    final c = text.codeUnitAt(q);
    if (!(_asciiAlnum(c) || c == 0x2D)) break;
    q++;
    n++;
  }
  return q + 1 < text.length &&
      text.codeUnitAt(q) == 0x2E &&
      _asciiAlnum(text.codeUnitAt(q + 1));
}

/// The end of the pattern's path at [p], a '/' or '?' and the characters
/// and '%XX' escapes after it up to whitespace, `" < > [ \ ] ^ ` { | }`, a
/// lone '%' or CJK punctuation.
int? _pathEnd(String text, int p) {
  if (p >= text.length) return null;
  final first = text.codeUnitAt(p);
  if (first != 0x2F && first != 0x3F) return null;
  var q = p + 1;
  while (q < text.length) {
    final c = text.codeUnitAt(q);
    if (c == 0x25) {
      if (q + 2 < text.length &&
          isHex(text.codeUnitAt(q + 1)) &&
          isHex(text.codeUnitAt(q + 2))) {
        q += 3;
        continue;
      }
      break;
    }
    final cp = cpAt(text, q);
    if (isIcuSpace(cp) ||
        '"<>[\\]^`{|}'.codeUnits.contains(c) ||
        isCjkPunctuation(c)) {
      break;
    }
    q += width(cp);
  }
  return q;
}

/// ux_path_start: the first '/', '?' or '#' of the web match [start, end)
/// past the "//" that follows a scheme.
int pathStart(String text, int start, int end) {
  var i = start;
  while (i < end && !_isAuthorityEnd(text.codeUnitAt(i), colon: true)) {
    i++;
  }
  if (i + 2 < end && text.startsWith('://', i)) i += 3;
  while (i < end && !_isAuthorityEnd(text.codeUnitAt(i), colon: false)) {
    i++;
  }
  return i;
}

bool _isAuthorityEnd(int c, {required bool colon}) =>
    c == 0x2F || c == 0x3F || c == 0x23 || colon && c == 0x3A;

/// ux_path_mark: the first character in [i, end) that Patterns.WEB_URL's
/// path does not take, or [end].
int pathMark(String text, int i, int end) {
  while (i < end) {
    final c = text.codeUnitAt(i);
    var next = i + 1;
    bool mark;
    if (c == 0x25) {
      mark =
          !(i + 2 < end &&
              isHex(text.codeUnitAt(i + 1)) &&
              isHex(text.codeUnitAt(i + 2)));
    } else if (c < 0x80) {
      mark = c <= 0x20 || c == 0x7F || '"<>[\\]^`{|}'.codeUnits.contains(c);
    } else if (c >= 0xD800 &&
        c <= 0xDBFF &&
        next < end &&
        text.codeUnitAt(next) >= 0xDC00 &&
        text.codeUnitAt(next) <= 0xDFFF) {
      mark = !isUcsChar(
        0x10000 + ((c - 0xD800) << 10) + (text.codeUnitAt(next++) - 0xDC00),
      );
    } else {
      mark = !isUcsChar(c);
    }
    if (mark) break;
    i = next;
  }
  return i;
}

/// ux_web_end: the end of the web match [start, end) before the first
/// character its path does not take, then before a trailing '.', ',', ';',
/// '!', '\'' or '(' and a trailing ')' it does not open.
int webEnd(String text, int start, int end) {
  end = pathMark(text, pathStart(text, start, end), end);
  var unopened = 0;
  for (var i = start; i < end; i++) {
    final c = text.codeUnitAt(i);
    if (c == 0x29) unopened++;
    if (c == 0x28) unopened--;
  }
  while (end > start) {
    final c = text.codeUnitAt(end - 1);
    if (c == 0x29 && unopened > 0) {
      unopened--;
    } else if (c == 0x28) {
      unopened++;
    } else if (!(c == 0x2E ||
        c == 0x2C ||
        c == 0x3B ||
        c == 0x21 ||
        c == 0x27)) {
      break;
    }
    end--;
  }
  return end;
}

/// ux_glues_word: whether the web match [start, end) is a host alone that a
/// '.' and a letterCharacterSet character outside the unspaced scripts
/// follow.
bool gluesWord(String text, int start, int end) {
  if (end + 1 >= text.length || text.codeUnitAt(end) != 0x2E) return false;
  for (var i = start; i < end; i++) {
    if (_isAuthorityEnd(text.codeUnitAt(i), colon: true)) return false;
  }
  final c = text.codeUnitAt(end + 1);
  return !isUnspacedUnit(c) && isMacLetter(cpAt(text, end + 1));
}

/// The end of the host of the web match [start, end), which has no scheme:
/// its first ':', '/', '?' or '#'.
int hostEnd(String text, int start, int end) {
  var i = start;
  while (i < end && !_isAuthorityEnd(text.codeUnitAt(i), colon: true)) {
    i++;
  }
  return i;
}

/// ux_has_tld: whether the web match [start, end), which has no scheme, has
/// an IPv4 address, or a host whose last label starts with an ASCII digit or
/// is a TLD.
bool hasTld(String text, int start, int end) {
  final host = hostEnd(text, start, end);
  var label = host;
  while (label > start && text.codeUnitAt(label - 1) != 0x2E) {
    label--;
  }
  if (label < text.length && isAsciiDigit(text.codeUnitAt(label))) return true;
  return isTld(text.substring(label, host));
}
