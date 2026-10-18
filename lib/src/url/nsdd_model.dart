import 'dart:convert';
import 'dart:typed_data';

import 'package:ux/src/url/chars.dart';

/// One NSDataDetector result: a link with its URL, or a phone number with its
/// phone string.
typedef NsddResult = ({int start, int end, bool phone, String value});

/// NSDataDetector's results of [text] (`.link | .phoneNumber`), in its order,
/// as macOS 26.4 reads them under en_US: scheme links, opaque URIs and
/// addresses that do not overlap, each read at its ':' or '@' from the left.
List<NsddResult> nsddResults(String text) {
  final scan = _Scan(text);
  final out = <NsddResult>[];
  var lastEnd = 0;
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if ((c != 0x3A && c != 0x40) || i < lastEnd) continue;
    final r = c == 0x3A ? scan.colonLink(i) : scan.address(i);
    if (r == null || r.start < lastEnd) continue;
    out.add(r);
    lastEnd = r.end;
  }
  return out;
}

/// The schemes NSDataDetector links with a body and no `//`.
const opaqueSchemes = {
  'sms',
  'tel',
  'callto',
  'maps',
  'xmpp',
  'sip',
  'im',
  'aim',
  'jabber',
  'news',
  'cid',
  'feed',
  'itms',
  'skype',
  'webcal',
};

/// The schemes NSDataDetector starts a link at after a '.' in a run of
/// scheme characters.
const _webSchemes = {'http', 'https', 'feed'};

/// What NSDataDetector reads of a link's authority.
sealed class _Authority {}

/// An authority NSDataDetector takes, its host from [host] to [hostEnd]
/// after any userinfo through [at].
final class _Taken extends _Authority {
  _Taken(this.at, this.host, this.hostEnd);

  final int? at;
  final int host;
  final int hostEnd;
}

/// An authority that ends NSDataDetector's link at [end].
final class _EndsAt extends _Authority {
  _EndsAt(this.end);

  final int end;
}

/// An authority that leaves NSDataDetector no link.
final class _Refused extends _Authority {}

/// [text] with the positions NSDataDetector's model looks ahead and back to,
/// each computed once.
class _Scan {
  _Scan(this.text) : n = text.length;

  final String text;
  final int n;

  late final Int32List _stops = _forward(_linkStop);
  late final Int32List _opens = _forward((c) => c == 0x28);
  late final Int32List _closes = _forward((c) => c == 0x29);
  late final Int32List _formats = _forward(
    (c) => _formatLike(c) && !_keptFormat(c),
  );
  late final Int32List _queries = _forward((c) => c == 0x3F);
  late final Int32List _lastCloses = _backward((c) => c == 0x29);
  late final Int32List _lastAts = _backward((c) => c == 0x40);
  late final Int32List _lastWordishes = _backward(_wordish);

  /// The last ')' before [p].
  int? _lastClose(int p) => _before(_lastCloses, p);

  /// The last '@' before [p].
  int? _lastAt(int p) => _before(_lastAts, p);

  /// The last character before [p] that ends a run of trailing marks.
  int? _lastWordish(int p) => _before(_lastWordishes, p);

  static int? _before(Int32List table, int p) {
    final at = table[p];
    return at < 0 ? null : at;
  }

  /// For each position, the first at or after it whose unit [test] holds,
  /// or the text's length.
  Int32List _forward(bool Function(int) test) {
    final out = Int32List(n + 1)..[n] = n;
    for (var i = n - 1; i >= 0; i--) {
      out[i] = test(text.codeUnitAt(i)) ? i : out[i + 1];
    }
    return out;
  }

  /// For each position, the last before it whose unit [test] holds, or -1,
  /// read through [_before].
  Int32List _backward(bool Function(int) test) {
    final out = Int32List(n + 1)..[0] = -1;
    for (var i = 1; i <= n; i++) {
      out[i] = test(text.codeUnitAt(i - 1)) ? i - 1 : out[i - 1];
    }
    return out;
  }

  /// Where a '(' that no ')' after it closes, or a ')' that no '(' before it
  /// opens, between [p] and [stop] ends NSDataDetector's link.
  int parenStop(int p, int stop) {
    var end = stop;
    final firstOpen = _opens[p];
    final firstClose = _closes[p];
    if (firstClose < firstOpen && firstClose < end) end = firstClose;
    final lastClose = _lastClose(stop);
    final from = lastClose != null && lastClose >= p ? lastClose + 1 : p;
    final open = _opens[from];
    if (open < end) end = open;
    return end;
  }

  /// The end of the run that [p] starts, before a hard stop and a paren
  /// stop.
  int runEnd(int p) => parenStop(p, _stops[p]);

  /// The link NSDataDetector reads at the ':' at [colon]: a scheme link where
  /// two '/' follow it, else an opaque URI.
  NsddResult? colonLink(int colon) {
    final p = _slashesEnd(colon);
    if (p == null) return _opaque(colon);
    final s = _schemeStart(colon);
    if (s == null) return null;
    final end = _schemeLinkEnd(s, colon, p) ?? _schemeSlash(s, colon, p);
    if (end == null) return null;
    return (start: s, end: end, phone: false, value: text.substring(s, end));
  }

  /// The end of the two '/' after the ':' at [colon], with any LRM and RLM
  /// before and between them, or null where none follow it.
  int? _slashesEnd(int colon) {
    var i = colon + 1;
    for (var slash = 0; slash < 2; slash++) {
      while (i < n &&
          (text.codeUnitAt(i) == 0x200E || text.codeUnitAt(i) == 0x200F)) {
        i++;
      }
      if (i >= n || text.codeUnitAt(i) != 0x2F) return null;
      i++;
    }
    return i;
  }

  /// Where NSDataDetector starts the scheme that ends at [sep], or null: the
  /// first ASCII letter of the run of scheme characters before it that no
  /// letter or digit precedes, or a web scheme after a '.' in the run.
  int? _schemeStart(int sep) {
    var run = sep;
    while (run > 0 && _schemeChar(text.codeUnitAt(run - 1))) {
      run--;
    }
    for (var dot = sep - 1; dot >= run; dot--) {
      if (text.codeUnitAt(dot) != 0x2E) continue;
      if (_webSchemes.contains(text.substring(dot + 1, sep).toLowerCase())) {
        return dot + 1;
      }
      break;
    }
    for (var p = run; p < sep; p++) {
      final c = text.codeUnitAt(p);
      if (!isAsciiLetter(c)) continue;
      if (p > run) {
        if (isAsciiLetter(text.codeUnitAt(p - 1)) ||
            isAsciiDigit(text.codeUnitAt(p - 1))) {
          continue;
        }
        return p;
      }
      return _gluedBefore(text, p) ? null : p;
    }
    return null;
  }

  /// The end of NSDataDetector's link for the scheme that starts at [s] and
  /// whose ':' at [sep] and slashes end at [p], or null where it reads none.
  ///
  /// The link runs to a hard or paren stop. A Cf character in its path cuts
  /// it back before its segment, or a bidi control at a segment's end ends
  /// it there, and a ZWJ ending it cuts its last segment. A '/' alone or an
  /// empty port's ':' goes before a control, '"', '<', ZWSP or a private-use
  /// character. Its trailing marks go, and then its authority decides.
  int? _schemeLinkEnd(int s, int sep, int p) {
    final scheme = text.substring(s, sep).toLowerCase();
    var stop = runEnd(p);
    var authorityEnd = p;
    while (authorityEnd < stop &&
        !_isPathStart(text.codeUnitAt(authorityEnd))) {
      authorityEnd++;
    }
    final format = _formats[authorityEnd];
    if (format < stop) {
      final c = text.codeUnitAt(format);
      final next = format + 1 < n ? text.codeUnitAt(format + 1) : 0x20;
      if (_bidiStop(c) &&
          (format + 1 == stop || _segmentEnd(next) || next <= 0x20)) {
        stop = format;
      } else {
        stop = _segmentBefore(format, authorityEnd);
      }
    }
    if (stop > authorityEnd &&
        text.codeUnitAt(stop - 1) == 0x200D &&
        (stop == n || text.codeUnitAt(stop) <= 0x20)) {
      stop = _segmentBefore(stop - 1, authorityEnd);
    }
    if (stop < n &&
        stop > p &&
        _dropsLonePath(text.codeUnitAt(stop)) &&
        (stop == authorityEnd + 1 && text.codeUnitAt(authorityEnd) == 0x2F ||
            stop == authorityEnd && text.codeUnitAt(stop - 1) == 0x3A)) {
      stop--;
      if (stop < authorityEnd) authorityEnd = stop;
    }
    final word = _lastWordish(stop);
    final pathWord = word != null && word >= authorityEnd;
    var authority = pathWord ? _authority(s, p, authorityEnd) : null;
    if (authority is _Refused) return null;
    if (authority is _EndsAt) return authority.end;
    final end = _trailing(s, stop);
    if (authority == null) {
      if (authorityEnd > end) authorityEnd = end;
      authority = _authority(s, p, authorityEnd);
    }
    switch (authority) {
      case _Refused():
        return null;
      case _EndsAt(:final end):
        return end;
      case _Taken(:final at, :final host, :final hostEnd):
        if (host == hostEnd &&
            at == null &&
            hostEnd == authorityEnd &&
            end == authorityEnd) {
          final alone = end == p && (p == n || _space(text.codeUnitAt(p)));
          return opaqueSchemes.contains(scheme) && alone ? p : null;
        }
        if (at != null && host == hostEnd && end == authorityEnd) return null;
        return end;
    }
  }

  /// The end of the segment before the one that holds [i], no earlier than
  /// [from].
  int _segmentBefore(int i, int from) {
    var cut = i;
    while (cut > from && !_segmentEnd(text.codeUnitAt(cut - 1))) {
      cut--;
    }
    return cut > from ? cut - 1 : from;
  }

  /// What NSDataDetector reads of the authority from [p] to [authorityEnd] of
  /// the link that starts at [s]: userinfo through its last '@', a bracketed
  /// literal or a host, and an empty or digit port.
  _Authority _authority(int s, int p, int authorityEnd) {
    final lastAt = _lastAt(authorityEnd);
    final at = lastAt != null && lastAt >= p ? lastAt : null;
    final host = at == null ? p : at + 1;
    int hostEnd;
    if (host < authorityEnd && text.codeUnitAt(host) == 0x5B) {
      var close = host + 1;
      while (close < authorityEnd && text.codeUnitAt(close) != 0x5D) {
        final c = text.codeUnitAt(close);
        if (_formatLike(c) && c != 0xAD) return _Refused();
        close++;
      }
      if (close >= authorityEnd) return _Refused();
      hostEnd = close + 1;
      while (hostEnd < authorityEnd && _ignorable(text.codeUnitAt(hostEnd))) {
        hostEnd++;
      }
    } else {
      hostEnd = host;
      while (hostEnd < authorityEnd && text.codeUnitAt(hostEnd) != 0x3A) {
        final c = text.codeUnitAt(hostEnd);
        if (_foreignDigit(cpAt(text, hostEnd))) {
          var cut = _wordStart(text, hostEnd, host);
          while (cut > host && _isDotOrDash(text.codeUnitAt(cut - 1))) {
            cut--;
          }
          for (var i = host; i < cut; i++) {
            if (isLetterMarkDigit(cpAt(text, i))) return _EndsAt(cut);
          }
          return _Refused();
        }
        if (_bidiStop(c) && hostEnd + 1 == authorityEnd && hostEnd > host) {
          return _EndsAt(_trailing(s, hostEnd));
        }
        if (_killsHost(c)) return _Refused();
        hostEnd++;
      }
      while (hostEnd > host && text.codeUnitAt(hostEnd - 1) == 0x200C) {
        hostEnd--;
      }
    }
    if (hostEnd < authorityEnd) {
      if (text.codeUnitAt(hostEnd) != 0x3A) return _Refused();
      var d = hostEnd + 1;
      while (d < authorityEnd && _portChar(text.codeUnitAt(d))) {
        d++;
      }
      if (d < authorityEnd) {
        final c = text.codeUnitAt(d);
        if (isDigit(c) || (_formatLike(c) && !(c >= 0x200C && c <= 0x200F))) {
          return _EndsAt(_trailing(s, hostEnd));
        }
        return _Refused();
      }
    }
    return _Taken(at, host, hostEnd);
  }

  /// NSDataDetector's reading of a scheme on the opaque list and one '/'
  /// where it reads no host after its `//` at [p] and no whitespace follows
  /// it.
  int? _schemeSlash(int s, int sep, int p) {
    if (!opaqueSchemes.contains(text.substring(s, sep).toLowerCase()) ||
        p != sep + 3) {
      return null;
    }
    if (p >= n || _space(text.codeUnitAt(p))) return null;
    return sep + 2;
  }

  /// The end of NSDataDetector's link from [s] to [end] after its trailing
  /// marks: a trimmed mark that is not the first of the run and that anything
  /// but '/' follows ends the link there, dropping the character before it
  /// too, and the run of `# - ~ *` before that, where `# - ~ *` or a '('
  /// follows it; then the trailing trimmed marks go.
  int _trailing(int s, int end) {
    final word = _lastWordish(end);
    final run = word != null && word >= s ? word + 1 : s;
    for (var i = run + 1; i < end; i++) {
      if (!_trimmed(text.codeUnitAt(i))) continue;
      final next = i + 1 < n ? text.codeUnitAt(i + 1) : 0x20;
      if (next == 0x2F) continue;
      if (i + 1 == end && next != 0x28) continue;
      end = i;
      if (_dropsBefore(next) || next == 0x28) {
        while (end > run) {
          final c = text.codeUnitAt(--end);
          if (!_dropsBefore(c)) break;
        }
      }
      break;
    }
    while (end > s && _trimmed(text.codeUnitAt(end - 1))) {
      end--;
    }
    return end;
  }

  /// The opaque URI NSDataDetector reads at the ':' at [colon]: a scheme on
  /// the opaque list or `mailto`, glued to no word, and a body of link
  /// characters that holds no Cf character other than the soft hyphen, ZWNJ,
  /// ZWJ, LRM and RLM, with its trailing marks and bidi controls dropped.
  NsddResult? _opaque(int colon) {
    var s = colon;
    while (s > 0 && isAsciiLetter(text.codeUnitAt(s - 1))) {
      s--;
    }
    if (s == colon) return null;
    final scheme = text.substring(s, colon);
    final lower = scheme.toLowerCase();
    final mailto = lower == 'mailto';
    if (!mailto && !opaqueSchemes.contains(lower)) return null;
    if (lower == 'tel' && scheme != 'tel') return null;
    if (s > 0) {
      final before = text.codeUnitAt(s - 1);
      if (before == 0x5F ? lower != 'tel' : _gluedBefore(text, s)) return null;
      if (isAsciiDigit(before)) return null;
    }
    final body = colon + 1;
    var stop = runEnd(body);
    while (stop > body && _bidiStop(text.codeUnitAt(stop - 1))) {
      stop--;
    }
    if (_formats[body] < stop) return null;
    final e = _trailing(body, stop);
    if (e == body) return null;
    if (mailto && !_mailtoAddress(body, e)) return null;
    return (
      start: s,
      end: e,
      phone: false,
      value: mailto ? _escaped(text.substring(s, e)) : text.substring(s, e),
    );
  }

  /// Whether [body, end), a `mailto:` URI's body, holds an address
  /// NSDataDetector reads: before any '?', a local part and a domain of
  /// labels of ASCII letters, digits, '-' and '_' joined by single dots whose
  /// last label is letters, or a body that is a query holding an '@'.
  bool _mailtoAddress(int body, int end) {
    final query = _queries[body] < end ? _queries[body] : end;
    if (query == body) {
      final lastAt = _lastAt(end);
      return lastAt != null && lastAt >= body;
    }
    final at = _lastAt(query);
    if (at == null || at <= body) return false;
    final labels = text.substring(at + 1, query).split('.');
    if (labels.length < 2) return false;
    for (final label in labels) {
      if (label.isEmpty) return false;
      for (final c in label.codeUnits) {
        if (!(isAsciiLetter(c) || isAsciiDigit(c) || c == 0x2D || c == 0x5F)) {
          return false;
        }
      }
    }
    return labels.last.codeUnits.every(isAsciiLetter);
  }

  /// The address NSDataDetector reads at the '@' at [at] with no written
  /// `mailto:`: a local part that no '.' starts or ends and that no '@', Cf
  /// character or word-joining mark glues to, and a domain of labels of ASCII
  /// letters, digits, '-' and '_' and ALM, LRM or RLM joined by single dots,
  /// whose last label is letters or ends at the letters before a '-'.
  NsddResult? address(int at) {
    var start = at;
    while (start > 0 && _localChar(cpBefore(text, start))) {
      start -= width(cpBefore(text, start));
    }
    while (start < at && text.codeUnitAt(start) == 0x2E) {
      start++;
    }
    if (start == at || text.codeUnitAt(at - 1) == 0x2E) return null;
    if (start > 0) {
      final before = cpBefore(text, start);
      if (before == 0x40 || _formatLike(before) && before != 0x200B) {
        return null;
      }
      if (_midLetter(before) &&
          start >= 2 &&
          isLetter(cpBefore(text, start - width(before)))) {
        return null;
      }
    }
    if (start >= 7 &&
        text.substring(start - 7, start).toLowerCase() == 'mailto:') {
      return null;
    }
    final end = _domainEnd(at + 1);
    if (end == null) return null;
    return (
      start: start,
      end: end,
      phone: false,
      value:
          'mailto:${_escaped(text.substring(start, at))}@'
          '${text.substring(at + 1, end)}',
    );
  }

  /// The end of an address's domain at [p]: two or more labels joined by
  /// single dots whose last label is letters, or ends at the letters before a
  /// '-' in it.
  int? _domainEnd(int p) {
    var i = p;
    var labels = 0;
    int? end;
    while (true) {
      final labelStart = i;
      while (i < n && _domainChar(text.codeUnitAt(i))) {
        i++;
      }
      if (i == labelStart) break;
      labels++;
      if (labels >= 2) {
        var letters = labelStart;
        while (letters < i && !_domainDigitOrMark(text.codeUnitAt(letters))) {
          letters++;
        }
        if (letters == i) end = i;
        if (letters < i) {
          if (letters > labelStart && text.codeUnitAt(letters) == 0x2D) {
            end = letters;
          }
          break;
        }
      }
      if (i + 1 < n &&
          text.codeUnitAt(i) == 0x2E &&
          _domainChar(text.codeUnitAt(i + 1))) {
        i++;
        continue;
      }
      break;
    }
    if (end == null) return null;
    if (end < n &&
        _formatLike(text.codeUnitAt(end)) &&
        !_bidiStop(text.codeUnitAt(end))) {
      return null;
    }
    return end;
  }
}

bool _schemeChar(int c) =>
    isAsciiLetter(c) || isAsciiDigit(c) || c == 0x2B || c == 0x2E || c == 0x2D;

/// Whether NSDataDetector's word joins the character at [i] of [text] to
/// what precedes it: a letter or digit outside Han, kana and Hangul, or such
/// a letter and a ':', '：' or '.', ends there, skipping marks and Cf
/// characters other than U+200B.
bool _gluedBefore(String text, int i) {
  var afterMid = false;
  while (i > 0) {
    final cp = cpBefore(text, i);
    if (isMark(cp) || _formatLike(cp) && cp != 0x200B) {
      i -= width(cp);
      continue;
    }
    if (_joinsWord(cp)) return !afterMid || isLetter(cp);
    if (!afterMid && (cp == 0x3A || cp == 0xFF1A || cp == 0x2E)) {
      afterMid = true;
      i -= 1;
      continue;
    }
    return false;
  }
  return false;
}

/// Whether [cp] joins a word as NSDataDetector reads one: a Hangul filler,
/// or a letter or digit outside Han, kana and Hangul.
bool _joinsWord(int cp) =>
    _isHangulFiller(cp) ||
    (isLetter(cp) || isDigit(cp)) &&
        !(cp >= 0x1100 && cp <= 0x11FF) &&
        !(cp >= 0x2E80 && cp <= 0x9FFF) &&
        !(cp >= 0xA960 && cp <= 0xA97F) &&
        !(cp >= 0xAC00 && cp <= 0xD7FF) &&
        !(cp >= 0xF900 && cp <= 0xFAFF) &&
        !(cp >= 0xFF66 && cp <= 0xFFDC) &&
        !(cp >= 0x20000 && cp <= 0x3FFFF);

/// Whether [cp] joins two letters into one word: ':', '·' and the other
/// MidLetter characters.
bool _midLetter(int cp) =>
    cp == 0x3A ||
    cp == 0xB7 ||
    cp == 0x0387 ||
    cp == 0x05F4 ||
    cp == 0x2027 ||
    cp == 0xFE13 ||
    cp == 0xFE55 ||
    cp == 0xFF1A;

bool _isHangulFiller(int cp) =>
    cp == 0x115F || cp == 0x1160 || cp == 0x3164 || cp == 0xFFA0;

/// Whether the UTF-16 unit [c] ends NSDataDetector's link before it:
/// whitespace, a C0 or C1 control or DEL, `{ } < > "`, CJK punctuation,
/// ZWSP or a private-use character.
bool _linkStop(int c) =>
    c <= 0x20 ||
    (c >= 0x7F && c <= 0xA0) ||
    c == 0x22 ||
    c == 0x3C ||
    c == 0x3E ||
    c == 0x7B ||
    c == 0x7D ||
    c == 0x1680 ||
    (c >= 0x2000 && c <= 0x200B) ||
    c == 0x2028 ||
    c == 0x2029 ||
    c == 0x202F ||
    c == 0x205F ||
    c == 0x3000 ||
    (c >= 0xE000 && c <= 0xF8FF) ||
    isCjkPunctuation(c);

/// Whether a path that is a '/' alone, or an empty port's ':', goes where the
/// UTF-16 unit [c] follows it.
bool _dropsLonePath(int c) =>
    (c <= 0x1F && !(c >= 0x09 && c <= 0x0D)) ||
    (c >= 0x7F && c <= 0x9F) ||
    c == 0x22 ||
    c == 0x3C ||
    c == 0x200B ||
    (c >= 0xE000 && c <= 0xF8FF);

/// Whether the UTF-16 unit [c] is a Cf character NSDataDetector keeps in a
/// link: the soft hyphen, ZWNJ, ZWJ, LRM and RLM.
bool _keptFormat(int c) => c == 0xAD || (c >= 0x200C && c <= 0x200F);

/// Whether the UTF-16 unit [c] is a bidi control other than LRM and RLM.
bool _bidiStop(int c) => isBidiControl(c) && c != 0x200E && c != 0x200F;

/// Whether the UTF-16 unit [c] ends a link's path segment.
bool _segmentEnd(int c) =>
    c == 0x2F || c == 0x3F || c == 0x23 || c == 0x3D || c == 0x26;

bool _isPathStart(int c) => c == 0x2F || c == 0x3F || c == 0x23;

/// Whether the UTF-16 unit [c] is Cf or U+2065, which NSDataDetector reads as
/// one.
bool _formatLike(int c) => isFormat(c) || c == 0x2065;

/// Whether the UTF-16 unit [c] is a default-ignorable character
/// NSDataDetector reads as part of a word: a Hangul filler or CGJ.
bool _ignorable(int c) => _isHangulFiller(c) || c == 0x034F;

bool _isDotOrDash(int c) => c == 0x2E || c == 0x2D;

/// Whether [cp] is a decimal digit outside ASCII and the fullwidth forms.
bool _foreignDigit(int cp) =>
    cp >= 0x80 && isDigit(cp) && !(cp >= 0xFF10 && cp <= 0xFF19);

/// Whether [cp] joins a word as ICU's word boundaries read one in a host: a
/// letter outside Han, kana and Hangul, a mark, a digit or '_'.
bool _hostWord(int cp) =>
    cp == 0x5F || isMark(cp) || isDigit(cp) || isLetter(cp) && _joinsWord(cp);

/// The start of the word that holds the character at [i] of [text], no
/// earlier than [from]: word characters join, and a '.' joins two letters
/// or two digits.
int _wordStart(String text, int i, int from) {
  var j = i;
  while (j > from) {
    final before = cpBefore(text, j);
    if (_hostWord(before)) {
      j -= width(before);
      continue;
    }
    if (before == 0x2E && j - 1 > from) {
      final left = cpBefore(text, j - 1);
      final right = cpAt(text, j);
      if (isDigit(left) && isDigit(right) ||
          isLetter(left) && isLetter(right)) {
        j -= 1;
        continue;
      }
    }
    break;
  }
  return j;
}

/// Whether the UTF-16 unit [c] in a link's host means no link.
bool _killsHost(int c) =>
    c == 0x5B ||
    c == 0x5D ||
    c == 0x60 ||
    c == 0x7C ||
    c == 0x5C ||
    c == 0x5E ||
    c == 0x2026 ||
    _formatLike(c) && c != 0xAD && c != 0x200C && c != 0x200D;

/// Whether the UTF-16 unit [c] is a port character: an ASCII or fullwidth
/// digit, or a default-ignorable character NSDataDetector keeps in a port.
bool _portChar(int c) =>
    _portDigit(c) ||
    c == 0xAD ||
    c == 0x034F ||
    c == 0xFE0F ||
    _isHangulFiller(c);

bool _space(int c) => c == 0x0B || isIcuSpace(c);

bool _portDigit(int c) => isAsciiDigit(c) || (c >= 0xFF10 && c <= 0xFF19);

/// Whether the UTF-16 unit [c] is a mark NSDataDetector drops from a link's
/// end.
bool _trimmed(int c) =>
    c == 0x2E ||
    c == 0x2C ||
    c == 0x3B ||
    c == 0x21 ||
    c == 0x201D ||
    c == 0x2026;

/// Whether the UTF-16 unit [c] is a mark that, after a trimmed mark, drops
/// the character before that mark too.
bool _dropsBefore(int c) => c == 0x23 || c == 0x2D || c == 0x7E || c == 0x2A;

/// Whether [c] is a letter, digit or other character that ends a run of
/// trailing marks.
bool _wordish(int c) =>
    !(_trimmed(c) ||
        c == 0x3A ||
        c == 0x3F ||
        c == 0x27 ||
        c == 0x2F ||
        _dropsBefore(c) ||
        c == 0x28);

/// Whether [cp] is a character of an address's local part as NSDataDetector
/// reads one: ASCII atext, '.', a letter, mark or digit outside the unspaced
/// scripts or a Hangul syllable, or a bidi control.
bool _localChar(int cp) => cp < 0x80
    ? isAsciiLetter(cp) ||
          isAsciiDigit(cp) ||
          "!#\$%&'*+/=?^_`{|}~.-".codeUnits.contains(cp)
    : isBidiControl(cp) ||
          isLetterMarkDigit(cp) &&
              (!isUnspaced(cp) || cp >= 0xAC00 && cp <= 0xD7A3);

bool _domainChar(int c) =>
    isAsciiLetter(c) ||
    isAsciiDigit(c) ||
    c == 0x2D ||
    c == 0x5F ||
    c == 0x061C ||
    c == 0x200E ||
    c == 0x200F;

bool _domainDigitOrMark(int c) => isAsciiDigit(c) || c == 0x2D || c == 0x5F;

/// [url] with each character NSDataDetector's URL escapes as UTF-8 '%XX'
/// escapes: `" # % < > [ \ ] ^ ` { | }`, controls, spaces and non-ASCII.
String _escaped(String url) {
  final out = StringBuffer();
  for (final rune in url.runes) {
    if (rune < 0x80 &&
        rune > 0x20 &&
        !'"#%<>[\\]^`{|}'.codeUnits.contains(rune)) {
      out.writeCharCode(rune);
      continue;
    }
    for (final byte in utf8.encode(String.fromCharCode(rune))) {
      out.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return out.toString();
}

/// The TLDs NSDataDetector links a bare host with a non-ASCII label on, as
/// macOS 26.4 reads `see bücher.<tld> x`, in src/tld.h's order.
final nsddBareTldList = _nsddBare.split(' ');

/// [nsddBareTldList] as a set.
final nsddBareTlds = nsddBareTldList.toSet();

const _nsddBare =
    'ae ai ar at au be bg bid biz bo br bs ca cc ch cl club cm cn co com cx cz '
    'de dk edu ee es eu fi fm fr gdn gl google gov gr hk hn hr hu id ie il in '
    'info io ir is it jo jp kr la lc li link lk loan lt lu lv ly ma me ms mx '
    'my net nl no nz online org ph pk pl pn pt pw ro rs ru sa se sg si site sk '
    'so social st tech th tm tn to tr tt tv tw ua uk us uy va vip vn wang win '
    'xin xyz za \u0440\u0443\u0441 \u0440\u0444 \u0443\u043A\u0440 '
    '\u0627\u0644\u0633\u0639\u0648\u062F\u064A\u0629 '
    '\u0627\u0645\u0627\u0631\u0627\u062A \u0645\u0635\u0631 '
    '\u0645\u0644\u064A\u0633\u064A\u0627 \u092D\u093E\u0930\u0924 '
    '\u0A2D\u0A3E\u0A30\u0A24 \u0AAD\u0ABE\u0AB0\u0AA4 \u0E44\u0E17\u0E22 '
    '\uD55C\uAD6D';
