import 'package:ux/src/url/chars.dart';
import 'package:ux/src/url/tld.dart';

/// A link of the second pass: its span, and whether it writes a scheme.
typedef PassLink = ({int start, int end, bool written});

/// url_detect.mm's second pass over the text [text] holds from [lo] to [hi],
/// read as a text of its own, at each start from [from] to [to]: the matches
/// of its case-insensitive ICU pattern, Patterns.WEB_URL's http, https, rtsp
/// and ftp links with a host of two or more labels or an IPv4 address, and
/// its hosts of ASCII labels and IPv4 addresses with no scheme, each ended
/// by [webEnd].
///
/// A host with no scheme links where its TLD is listed, no '.' and letter
/// glue a word to it, no word character outside the unspaced scripts
/// follows it, no '://' follows it, and, an IPv4 address, no octet of two
/// or more digits starts with '0' and no '.' and digit follow it; a port of
/// fullwidth digits that an unspaced character follows joins it. With [idn],
/// the pass reads labels that also hold letters, marks and digits outside
/// ASCII and the unspaced scripts, and gives only the hosts with no scheme
/// that hold one.
List<PassLink> webPass(
  String text,
  int lo,
  int hi,
  int from,
  int to, {
  bool idn = false,
}) {
  final pass = _Pass(text, lo, hi, idn);
  List<PassLink>? out;
  var s = from;
  while (s < to) {
    final matchEnd = pass.matchAt(s);
    if (matchEnd == null) {
      s += width(cpAtIn(text, s, hi));
      continue;
    }
    final written = pass.written;
    var end = webEnd(text, s, matchEnd);
    if (!written) end = pass.bareEnd(s, end);
    if (end > s && (written ? !idn : pass.keepsBare(s, end))) {
      (out ??= []).add((start: s, end: end, written: written));
    }
    s = matchEnd;
  }
  return out ?? const [];
}

class _Pass {
  _Pass(this.text, this.lo, this.hi, this.idn);

  final String text;
  final int lo;
  final int hi;
  final bool idn;

  /// Whether the last match [matchAt] gave writes a scheme.
  bool written = false;

  int _cp(int i) => cpAtIn(text, i, hi);

  int _cpBefore(int i) => cpBeforeIn(text, i, lo);

  /// The end of the pattern's match at [s], or null.
  int? matchAt(int s) {
    final c = text.codeUnitAt(s);
    if (!(isAsciiDigit(c) ||
        isAsciiLetter(c) ||
        c == 0x17F ||
        c == 0x212A ||
        idn && c >= 0x80 && _idnLetterOrDigit(_cp(s)))) {
      return null;
    }
    if (!_startsMatch(s)) return null;
    final scheme = _schemeEnd(s);
    if (scheme != null) {
      final userinfo = _userinfoEnd(scheme);
      if (userinfo != null) {
        final end = _host(userinfo, scheme: true);
        if (end != null) return _match(end, true);
      }
      final end = _host(scheme, scheme: true);
      if (end != null) return _match(end, true);
    }
    final end = _host(s, scheme: false);
    return end == null ? null : _match(end, false);
  }

  int _match(int end, bool scheme) {
    written = scheme;
    return end;
  }

  /// The pattern's start: a word boundary, or after a '_' or an unspaced
  /// letter, but neither after a letter, mark or digit outside the unspaced
  /// scripts and a run of 1 to 62 '_' and '-' or a '.', nor after "://".
  /// Before that test, a run of Cf characters and Hangul fillers is skipped:
  /// a host starts after one that an unspaced character precedes, and none
  /// after one that a letter, mark or digit outside the unspaced scripts
  /// precedes.
  bool _startsMatch(int s) {
    if (s > lo) {
      final before = _cpBefore(s);
      if (before >= 0xAD && _skipped(before)) {
        var j = s - width(before);
        while (j > lo && _skipped(_cpBefore(j))) {
          j -= width(_cpBefore(j));
        }
        if (j > lo) {
          final b = _cpBefore(j);
          if (isUnspaced(b)) return true;
          if (isSpacedLetterMarkDigit(b)) return false;
        }
      }
    }
    if (!_boundary(s) &&
        !(s > lo &&
            (text.codeUnitAt(s - 1) == 0x5F || isUnspaced(_cpBefore(s))))) {
      return false;
    }
    if (s - 1 > lo &&
        text.codeUnitAt(s - 1) == 0x2E &&
        isSpacedLetterMarkDigit(_cpBefore(s - 1))) {
      return false;
    }
    var run = 0;
    while (run < 63 &&
        s - run > lo &&
        _isDashOrUnderscore(text.codeUnitAt(s - run - 1))) {
      run++;
    }
    if (run >= 1 &&
        run <= 62 &&
        s - run > lo &&
        isSpacedLetterMarkDigit(_cpBefore(s - run))) {
      return false;
    }
    return !(s - 3 >= lo && text.startsWith('://', s - 3));
  }

  /// Whether ICU's `\b` holds at [i].
  bool _boundary(int i) => wordBoundaryIn(text, i, lo, hi);

  /// Whether ICU's `$` holds at [i]: at the text's end, or before a line
  /// terminator that ends it.
  bool _textEnd(int i) {
    if (i == hi) return true;
    final c = text.codeUnitAt(i);
    if (i == hi - 1) {
      return (c >= 0x0A && c <= 0x0D) ||
          c == 0x85 ||
          c == 0x2028 ||
          c == 0x2029;
    }
    return i == hi - 2 && c == 0x0D && text.codeUnitAt(i + 1) == 0x0A;
  }

  bool _literal(int i, String word) {
    if (i + word.length > hi) return false;
    for (var k = 0; k < word.length; k++) {
      final l = word.codeUnitAt(k);
      final c = text.codeUnitAt(i + k);
      if (isAsciiLetter(l) ? !_letterIs(c, l) : c != l) return false;
    }
    return true;
  }

  bool _startsWithIn(String prefix, int i) =>
      i + prefix.length <= hi && text.startsWith(prefix, i);

  /// The end of `(?:https?|rtsp|ftp)://` at [s].
  int? _schemeEnd(int s) {
    if (_literal(s, 'http')) {
      final p = s + 4;
      if (p < hi && _letterIs(text.codeUnitAt(p), 0x73)) {
        if (_startsWithIn('://', p + 1)) return p + 4;
      }
      return _startsWithIn('://', p) ? p + 3 : null;
    }
    if (_literal(s, 'rtsp://')) return s + 7;
    if (_literal(s, 'ftp://')) return s + 6;
    return null;
  }

  /// The end of the user part's run of characters and '%XX' escapes at [p],
  /// at most [max] of them, and how many it holds.
  (int, int) _userRun(int p, int max) {
    var n = 0;
    while (n < max && p < hi) {
      final c = text.codeUnitAt(p);
      if (_userChar(c)) {
        p++;
      } else if (c == 0x25 &&
          p + 2 < hi &&
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
  int? _userinfoEnd(int p) {
    final (user, n) = _userRun(p, 64);
    if (n == 0 || user >= hi) return null;
    final c = text.codeUnitAt(user);
    if (c == 0x40) return user + 1;
    if (c != 0x3A) return null;
    final (pass, m) = _userRun(user + 1, 25);
    if (m == 0 || pass >= hi || text.codeUnitAt(pass) != 0x40) return null;
    return pass + 1;
  }

  bool _asciiAlnum(int cp) =>
      cp < 0x80 && (isAsciiLetter(cp) || isAsciiDigit(cp)) ||
      cp == 0x17F ||
      cp == 0x212A;

  bool _labelEdge(int cp, bool scheme) =>
      _asciiAlnum(cp) ||
      cp >= 0x80 && (scheme ? _ucs(cp) : idn && _idnLetterOrDigit(cp));

  bool _labelInner(int cp, bool scheme) =>
      _labelEdge(cp, scheme) || cp == 0x2D || cp == 0x5F;

  bool _tldChar(int cp, bool scheme) =>
      (cp < 0x80 && isAsciiLetter(cp)) ||
      cp == 0x17F ||
      cp == 0x212A ||
      cp >= 0x80 && (scheme ? _ucs(cp) : idn && _idnLetter(cp));

  /// The end of the label at [p] where a '.' follows it: 1 to 63 characters
  /// that a letter or digit starts and ends.
  int? _label(int p, bool scheme) {
    var q = p;
    var n = 0;
    while (n < 63 && q < hi) {
      final cp = _cp(q);
      if (!(n == 0 ? _labelEdge(cp, scheme) : _labelInner(cp, scheme))) break;
      q += width(cp);
      n++;
    }
    return n > 0 &&
            _labelEdge(_cpBefore(q), scheme) &&
            q < hi &&
            text.codeUnitAt(q) == 0x2E
        ? q
        : null;
  }

  /// The match's end after a host at [p]: labels and a TLD, or an IPv4
  /// address, then the pattern's port and tail, in ICU's backtracking order.
  int? _host(int p, {required bool scheme}) {
    final starts = <int>[];
    var at = p;
    while (true) {
      final dot = _label(at, scheme);
      if (dot == null) break;
      at = dot + 1;
      starts.add(at);
    }
    for (final start in starts.reversed) {
      final end = _tld(start, scheme);
      if (end != null) return end;
    }
    return idn || p >= hi || !isAsciiDigit(text.codeUnitAt(p))
        ? null
        : _ipv4(p, scheme);
  }

  /// The match's end after a TLD at [a], its ends tried longest first:
  /// `xn--` and up to 59 word characters and '-' that a word character ends,
  /// then 2 to 63 letters.
  int? _tld(int a, bool scheme) {
    final xn =
        a < hi &&
        text.codeUnitAt(a) | 0x20 == 0x78 &&
        (scheme ? _startsWithIn('xn--', a) : _literal(a, 'xn--'));
    if (xn) {
      var q = a + 4;
      var r = 0;
      while (r < 59 && q < hi) {
        final cp = _cp(q);
        if (!(_xnChar(cp, scheme) || cp == 0x2D)) break;
        q += width(cp);
        r++;
      }
      for (var e = q; e > a + 4;) {
        final cp = _cpBefore(e);
        if (_xnChar(cp, scheme)) {
          final end = _tail(e, scheme);
          if (end != null) return end;
        }
        e -= width(cp);
      }
    }
    var q = a;
    var n = 0;
    while (n < 63 && q < hi) {
      final cp = _cp(q);
      if (!_tldChar(cp, scheme)) break;
      q += width(cp);
      n++;
    }
    for (; n >= 2; n--) {
      final end = _tail(q, scheme);
      if (end != null) return end;
      q -= width(_cpBefore(q));
    }
    return null;
  }

  bool _xnChar(int cp, bool scheme) => scheme
      ? isWord(cp)
      : _asciiAlnum(cp) || cp >= 0x80 && idn && _idnLetterOrDigit(cp);

  int? _tail(int h, bool scheme) => scheme ? _portAfterScheme(h) : _tailBare(h);

  /// The match's end after an IPv4 address at [p], in the pattern's
  /// backtracking order.
  int? _ipv4(int p, bool scheme) {
    final a = _octets(p, false, false);
    for (var x = 3; x >= 1; x--) {
      if (a & (1 << x) == 0 || !_dotAt(p + x)) continue;
      final q = p + x + 1;
      final b = _octets(q, true, false);
      for (var y = 3; y >= 1; y--) {
        if (b & (1 << y) == 0 || !_dotAt(q + y)) continue;
        final r = q + y + 1;
        final c = _octets(r, true, false);
        for (var z = 3; z >= 1; z--) {
          if (c & (1 << z) == 0 || !_dotAt(r + z)) continue;
          final s = r + z + 1;
          final d = _octets(s, false, true);
          for (var w = 3; w >= 1; w--) {
            if (d & (1 << w) == 0) continue;
            final end = _tail(s + w, scheme);
            if (end != null) return end;
          }
        }
      }
    }
    return null;
  }

  bool _dotAt(int i) => i < hi && text.codeUnitAt(i) == 0x2E;

  int? _digitAt(int i) {
    if (i >= hi) return null;
    final c = text.codeUnitAt(i);
    return isAsciiDigit(c) ? c - 0x30 : null;
  }

  /// The lengths an IPv4 octet at [i] may take, as bits 1 to 3: 25[0-5],
  /// 2[0-4][0-9], [0-1][0-9]{2}, [1-9][0-9], then [1-9], '0' where [middle]
  /// holds, or [0-9] where [last] holds; the pattern tries them longest
  /// first.
  int _octets(int i, bool middle, bool last) {
    final a = _digitAt(i), b = _digitAt(i + 1), c = _digitAt(i + 2);
    var out = 0;
    if (a != null && b != null && c != null) {
      if (a == 2 && b == 5 && c <= 5 || a == 2 && b <= 4 || a <= 1) {
        out |= 1 << 3;
      }
    }
    if (a != null && a >= 1 && b != null) out |= 1 << 2;
    if (a != null && (last || a >= 1 || middle && a == 0)) out |= 1 << 1;
    return out;
  }

  /// After a written scheme's host at [h]: a port of ASCII digits that an
  /// unspaced letter follows, or any port, then a path or a word boundary.
  int? _portAfterScheme(int h) {
    if (h < hi && text.codeUnitAt(h) == 0x3A) {
      final ascii = _digits(h + 1, true);
      for (var e = ascii; e > h + 1; e--) {
        if (_unspacedAt(e)) return e;
      }
      final any = _digits(h + 1, false);
      for (var e = any; e > h + 1; e -= width(_cpBefore(e))) {
        final end = _pathOrBoundary(e);
        if (end != null) return end;
      }
    }
    return _pathOrBoundary(h);
  }

  /// The end of at most five digits at [i], ASCII where [ascii] holds.
  int _digits(int i, bool ascii) {
    var q = i;
    for (var n = 0; n < 5 && q < hi; n++) {
      final cp = _cp(q);
      if (!(ascii ? cp < 0x80 && isAsciiDigit(cp) : isDigit(cp))) break;
      q += width(cp);
    }
    return q;
  }

  bool _unspacedAt(int i) => i < hi && isUnspaced(_cp(i));

  int? _pathOrBoundary(int p) => _pathEnd(p) ?? (_boundary(p) ? p : null);

  /// After a host with no scheme at [h]: any port, then a path, or a word
  /// boundary, the text's end or an unspaced letter that '@' and an email's
  /// domain do not follow.
  int? _tailBare(int h) {
    if (h < hi && text.codeUnitAt(h) == 0x3A) {
      final ascii = _digits(h + 1, true);
      for (var e = ascii; e > h + 1; e--) {
        final end = _bareEnd(e);
        if (end != null) return end;
      }
      final any = _digits(h + 1, false);
      for (var e = any; e > h + 1; e -= width(_cpBefore(e))) {
        if (!_boundary(e)) continue;
        final end = _bareEnd(e);
        if (end != null) return end;
      }
    }
    return _bareEnd(h);
  }

  int? _bareEnd(int p) {
    final path = _pathEnd(p);
    if (path != null) return path;
    if ((_boundary(p) || _textEnd(p) || _unspacedAt(p)) && !_emailAhead(p)) {
      return p;
    }
    return null;
  }

  /// Whether `@`, a letter or digit, up to 64 letters, digits and '-', a '.'
  /// and a letter or digit follow [p].
  bool _emailAhead(int p) {
    if (p + 1 >= hi || text.codeUnitAt(p) != 0x40) return false;
    if (!_asciiAlnum(text.codeUnitAt(p + 1))) return false;
    var q = p + 2;
    var n = 0;
    while (n < 64 && q < hi) {
      final c = text.codeUnitAt(q);
      if (!(_asciiAlnum(c) || c == 0x2D)) break;
      q++;
      n++;
    }
    return q + 1 < hi &&
        text.codeUnitAt(q) == 0x2E &&
        _asciiAlnum(text.codeUnitAt(q + 1));
  }

  /// The end of the pattern's path at [p], a '/' or '?' and the characters
  /// and '%XX' escapes after it up to whitespace, `" < > [ \ ] ^ ` { | }`, a
  /// lone '%' or CJK punctuation.
  int? _pathEnd(int p) {
    if (p >= hi) return null;
    final first = text.codeUnitAt(p);
    if (first != 0x2F && first != 0x3F) return null;
    var q = p + 1;
    while (q < hi) {
      final c = text.codeUnitAt(q);
      if (c == 0x25) {
        if (q + 2 < hi &&
            isHex(text.codeUnitAt(q + 1)) &&
            isHex(text.codeUnitAt(q + 2))) {
          q += 3;
          continue;
        }
        break;
      }
      final cp = _cp(q);
      if (isIcuSpace(cp) || isPathStop(c) || isCjkPunctuation(c)) break;
      q += width(cp);
    }
    return q;
  }

  /// [end], the end of a host with no scheme at [s], run on over a ':' and
  /// fullwidth digits that an unspaced character follows.
  int bareEnd(int s, int end) {
    if (end >= hi || text.codeUnitAt(end) != 0x3A || !_hostOnly(s, end)) {
      return end;
    }
    var e = end + 1;
    while (e < hi && _fullwidthDigit(text.codeUnitAt(e))) {
      e++;
    }
    return e > end + 1 && e < hi && isUnspaced(_cp(e)) ? e : end;
  }

  bool _hostOnly(int s, int end) {
    for (var i = s; i < end; i++) {
      if (_isAuthorityMark(text.codeUnitAt(i))) return false;
    }
    return true;
  }

  /// Whether the host with no scheme from [s] to [end] links.
  bool keepsBare(int s, int end) {
    final host = hostEnd(text, s, end);
    if (idn && !_holdsNonAscii(s, host)) return false;
    if (!hasTld(text, s, end)) return false;
    if (_startsWithIn('://', end)) return false;
    if (end + 1 < hi &&
        text.codeUnitAt(end) == 0x2E &&
        host == end &&
        !isUnspacedUnit(text.codeUnitAt(end + 1)) &&
        isLetter(_cp(end + 1))) {
      return false;
    }
    if (end < hi && host == end) {
      final next = _cp(end);
      if (isWord(next) && !isUnspaced(next)) return false;
    }
    if (_ipv4Host(s, host) case final zeroLed?) {
      if (zeroLed) return false;
      if (end + 1 < hi &&
          text.codeUnitAt(end) == 0x2E &&
          isAsciiDigit(text.codeUnitAt(end + 1))) {
        return false;
      }
    }
    return true;
  }

  bool _holdsNonAscii(int from, int to) {
    for (var i = from; i < to; i++) {
      if (text.codeUnitAt(i) >= 0x80) return true;
    }
    return false;
  }

  /// Whether the host from [s] to [host] is four dot-separated runs of one
  /// to three ASCII digits, and whether one of two or more digits starts
  /// with '0'; null where it is not.
  bool? _ipv4Host(int s, int host) {
    var parts = 0;
    var zeroLed = false;
    var i = s;
    while (true) {
      final start = i;
      while (i < host && isAsciiDigit(text.codeUnitAt(i))) {
        i++;
      }
      final n = i - start;
      if (n == 0 || n > 3) return null;
      if (n >= 2 && text.codeUnitAt(start) == 0x30) zeroLed = true;
      parts++;
      if (i == host) break;
      if (text.codeUnitAt(i) != 0x2E) return null;
      i++;
    }
    return parts == 4 ? zeroLed : null;
  }
}

/// Whether the start test skips [cp]: a Cf character or a Hangul filler.
bool _skipped(int cp) =>
    isFormat(cp) ||
    cp == 0x115F ||
    cp == 0x1160 ||
    cp == 0x3164 ||
    cp == 0xFFA0;

/// Whether [cp] is a letter or mark outside ASCII and the unspaced scripts.
bool _idnLetter(int cp) => !isUnspaced(cp) && (isLetter(cp) || isMark(cp));

/// Whether [cp] is a letter, mark or digit outside ASCII and the unspaced
/// scripts.
bool _idnLetterOrDigit(int cp) => isSpacedLetterMarkDigit(cp);

bool _fullwidthDigit(int u) => u >= 0xFF10 && u <= 0xFF19;

bool _isDashOrUnderscore(int c) => c == 0x5F || c == 0x2D;

bool _isAuthorityMark(int c) =>
    c == 0x2F || c == 0x3F || c == 0x23 || c == 0x3A;

/// Whether ICU's `\b` holds at [i] of the text from [lo] to [hi]: never
/// before a Grapheme_Extend or Cf character, and otherwise where the
/// character there and the one before it, skipping Grapheme_Extend and Cf
/// characters, differ in being `\w`.
bool wordBoundaryIn(String text, int i, int lo, int hi) {
  var here = false;
  if (i < hi) {
    final cp = cpAtIn(text, i, hi);
    if (isBoundaryTransparent(cp)) return false;
    here = isWord(cp);
  }
  var before = false;
  var j = i;
  while (j > lo) {
    final cp = cpBeforeIn(text, j, lo);
    j -= width(cp);
    if (!isBoundaryTransparent(cp)) {
      before = isWord(cp);
      break;
    }
  }
  return here != before;
}

/// Whether the UTF-16 unit [c] matches the lowercase ASCII letter [l] with
/// ICU's case closure, which adds U+017F to 's' and U+212A to 'k'.
bool _letterIs(int c, int l) =>
    (c | 0x20) == l && isAsciiLetter(c) ||
    (l == 0x73 && c == 0x17F) ||
    (l == 0x6B && c == 0x212A);

/// Whether [c] is in `[a-z0-9$_.+!*'(),;?&=-]` with ICU's case closure.
bool _userChar(int c) =>
    isAsciiLetter(c) ||
    isAsciiDigit(c) ||
    c == 0x17F ||
    c == 0x212A ||
    r"$_.+!*'(),;?&=-".codeUnits.contains(c);

/// Whether [cp] is in the pattern's UCS_CHAR set, which leaves out CJK
/// punctuation.
bool _ucs(int cp) => isUcsChar(cp) && !(cp <= 0xFFFF && isCjkPunctuation(cp));

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
      mark = c <= 0x20 || c == 0x7F || isPathStop(c);
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
  if (label < host && isAsciiDigit(text.codeUnitAt(label))) return true;
  return isTld(text.substring(label, host));
}
