import 'dart:typed_data';

import 'package:ux/src/url/chars.dart';
import 'package:ux/src/url/web_pass.dart';

/// NSDataDetector's links in the text [text] holds from [lo] to [hi], read as
/// a text of its own, at each ':' from [from] to [to], as macOS 26.4 reads
/// them under en_US: scheme links and opaque URIs that do not overlap, each
/// read at its ':' from the left and ended by [webEnd], as their spans.
List<(int, int)> nsddLinks(String text, int lo, int hi, int from, int to) {
  List<(int, int)>? out;
  _Scan? scan;
  var lastEnd = lo;
  for (var i = from; i < to; i++) {
    if (text.codeUnitAt(i) != 0x3A || i < lastEnd) continue;
    final r = (scan ??= _Scan(text, lo, hi)).colonLink(i);
    if (r == null || r.$1 < lastEnd) continue;
    lastEnd = r.$2;
    final end = webEnd(text, r.$1, r.$2);
    if (end > r.$1) (out ??= []).add((r.$1, end));
  }
  return out ?? const [];
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
/// scheme characters, and whose userinfo it refuses where its user ends in
/// a '.' and a label of two or three letters.
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

/// The text from [lo] to [hi] with the positions NSDataDetector's model
/// looks ahead and back to, each computed once.
class _Scan {
  _Scan(this.text, this.lo, this.hi);

  final String text;
  final int lo;
  final int hi;

  late final Int32List _stops = _forward(_linkStop);
  late final Int32List _opens = _forward((c) => c == 0x28);
  late final Int32List _closes = _forward((c) => c == 0x29);
  late final Int32List _formats = _forward(_cutsPath);
  late final Int32List _lastCloses = _backward((c) => c == 0x29);
  late final Int32List _lastAts = _backward((c) => c == 0x40);
  late final Int32List _lastWordishes = _backward(_wordish);
  late final Int32List _lastWords = () {
    final out = Int32List(hi - lo + 1)..[0] = -1;
    for (var i = lo + 1; i <= hi; i++) {
      final cp = cpBeforeIn(text, i, lo);
      out[i - lo] = _wordOrFormat(cp) ? i : out[i - lo - width(cp)];
    }
    return out;
  }();

  /// For each position, the first at or after it whose unit [test] holds,
  /// or [hi].
  Int32List _forward(bool Function(int) test) {
    final out = Int32List(hi - lo + 1)..[hi - lo] = hi;
    for (var i = hi - 1; i >= lo; i--) {
      out[i - lo] = test(text.codeUnitAt(i)) ? i : out[i - lo + 1];
    }
    return out;
  }

  /// For each position, the last before it whose unit [test] holds, or -1.
  Int32List _backward(bool Function(int) test) {
    final out = Int32List(hi - lo + 1)..[0] = -1;
    for (var i = lo + 1; i <= hi; i++) {
      out[i - lo] = test(text.codeUnitAt(i - 1)) ? i - 1 : out[i - lo - 1];
    }
    return out;
  }

  /// [table]'s position for [p], where it is at or after [from].
  int? _from(Int32List table, int from, int p) {
    final at = table[p - lo];
    return at >= from ? at : null;
  }

  /// The last ')' from [from] and before [p].
  int? _lastClose(int from, int p) => _from(_lastCloses, from, p);

  /// The last '@' from [from] and before [p].
  int? _lastAt(int from, int p) => _from(_lastAts, from, p);

  /// The last character from [from] and before [p] that ends a run of
  /// trailing marks.
  int? _lastWordish(int from, int p) => _from(_lastWordishes, from, p);

  /// The end of the last character in ICU's `\w` or Cf after [from] and at or
  /// before [p].
  int? _lastWordEnd(int from, int p) => _from(_lastWords, from + 1, p);

  /// The first Cf character other than the soft hyphen, ZWNJ, ZWJ, LRM and
  /// RLM at or after [p] and before [stop], or [stop].
  int _formatBefore(int p, int stop) {
    final at = _formats[p - lo];
    return at < stop ? at : stop;
  }

  /// Where a '(' that no ')' after it closes, or a ')' that no '(' before it
  /// opens, between [p] and [stop] ends NSDataDetector's link.
  int parenStop(int p, int stop) {
    var end = stop;
    final firstOpen = _opens[p - lo];
    final firstClose = _closes[p - lo];
    if (firstClose < firstOpen && firstClose < end) end = firstClose;
    final lastClose = _lastClose(p, stop);
    final open = _opens[(lastClose == null ? p : lastClose + 1) - lo];
    return open < end ? open : end;
  }

  /// The end of the run that [p] starts, before a hard stop and a paren
  /// stop.
  int runEnd(int p) => parenStop(p, _stops[p - lo]);

  /// [stop], the end of the run that [p] starts, or, where a unit of
  /// [_dropsRunBefore] follows it, the end [_tailEnd] reads for the run's
  /// tail after its last character in ICU's `\w` or Cf, else that
  /// character's end before a paren stop. [authorityEnd] ends a scheme
  /// link's authority, whose bracketed host's ']' a tail may start at.
  int _wordEnd(int p, int stop, [int? authorityEnd]) {
    if (stop >= hi || !_dropsRunBefore(text.codeUnitAt(stop))) return stop;
    final word = _lastWordEnd(p, stop) ?? p;
    final literal =
        authorityEnd != null && _literalClose(p, authorityEnd) == word;
    return _tailEnd(word, stop, literal) ?? parenStop(p, word);
  }

  /// The ']' that closes the bracketed host of the authority from [p] to
  /// [authorityEnd].
  int? _literalClose(int p, int authorityEnd) {
    final lastAt = _lastAt(p, authorityEnd);
    final host = lastAt == null ? p : lastAt + 1;
    if (host >= authorityEnd || text.codeUnitAt(host) != 0x5B) return null;
    for (var i = host + 1; i < authorityEnd; i++) {
      if (text.codeUnitAt(i) == 0x5D) return i;
    }
    return null;
  }

  /// Where NSDataDetector ends a link before a unit of [_dropsRunBefore]
  /// where its tail [word, stop) follows a letter, mark or ASCII digit and is
  /// at most three of `/ ' ? : # - ~ * . , ! ;`, after a bracketed host's
  /// ']' where [literal] holds, or null for any other tail.
  ///
  /// A trimmed mark inside the tail that no '/' follows ends the link as
  /// [_trailing] reads it. Otherwise `# - ~ *` before the stop go, then a
  /// '?', ':', ']' or trimmed mark goes with the run of `# - ~ *` before it
  /// and the character before that run. A '/' or apostrophe goes alone
  /// where [_tailKept] holds; else the character before it goes too, and
  /// after an apostrophe, where that character is one of `# - ~ *`, the rest
  /// of its run and the character before that run, or after a '/', where
  /// that character is not a '/' or apostrophe, one more character. The
  /// link ends no earlier than [word].
  int? _tailEnd(int word, int stop, bool literal) {
    final lead = cpBeforeIn(text, word, lo);
    if (stop - word > 3 || !isMacLetter(lead) && !isAsciiDigit(lead)) {
      return null;
    }
    for (var i = literal ? word + 1 : word; i < stop; i++) {
      if (!_tailChar(text.codeUnitAt(i))) return null;
    }
    for (var i = word + 1; i < stop - 1; i++) {
      final next = text.codeUnitAt(i + 1);
      if (!_trimmed(text.codeUnitAt(i)) || next == 0x2F) continue;
      return _dropsBefore(next) ? _dropRun(word, i) : i;
    }
    var e = stop;
    while (e > word) {
      final c = text.codeUnitAt(e - 1);
      if (_dropsBefore(c)) {
        e--;
        continue;
      }
      if (!_slashLike(c)) return _dropRun(word, e - 1);
      e--;
      if (_tailKept(word, e, c)) return e;
      final b = text.codeUnitAt(--e);
      if (c == 0x27) return _dropsBefore(b) ? _dropRun(word, e) : e;
      return !_slashLike(b) && e > word ? e - 1 : e;
    }
    return word;
  }

  /// [e] without the run of `# - ~ *` before it and the character before
  /// that run, no earlier than [word].
  int _dropRun(int word, int e) {
    while (e > word) {
      if (!_dropsBefore(text.codeUnitAt(--e))) break;
    }
    return e;
  }

  /// Whether a tail from [word] that ends at [e] before the '/' or
  /// apostrophe [c] stays before a hard stop: it is empty, or its last
  /// character is not a trimmed mark and the one before that is the
  /// character before [word], an apostrophe, ']' or a trimmed mark, or the
  /// two are `//`, `--` or `**`, or `:/` before a '/'.
  bool _tailKept(int word, int e, int c) {
    if (e == word) return true;
    final b = text.codeUnitAt(e - 1);
    if (_trimmed(b)) return false;
    if (e - 1 == word) return true;
    final a = text.codeUnitAt(e - 2);
    return a == 0x27 ||
        a == 0x5D ||
        _trimmed(a) ||
        a == b && (a == 0x2F || a == 0x2D || a == 0x2A) ||
        c == 0x2F && a == 0x3A && b == 0x2F;
  }

  /// The link NSDataDetector reads at the ':' at [colon]: a scheme link where
  /// two '/' follow it, else an opaque URI; none for `mailto`.
  (int, int)? colonLink(int colon) {
    final p = _slashesEnd(colon);
    if (p == null) return _opaque(colon);
    final s = _schemeStart(colon);
    if (s == null || _isMailto(s, colon)) return null;
    final end = _schemeLinkEnd(s, colon, p) ?? _schemeSlash(s, colon, p);
    return end == null ? null : (s, end);
  }

  /// Whether the scheme from [s] to [sep] is `mailto` in any case.
  bool _isMailto(int s, int sep) {
    if (sep - s != 6) return false;
    for (var k = 0; k < 6; k++) {
      if (text.codeUnitAt(s + k) | 0x20 != 'mailto'.codeUnitAt(k)) {
        return false;
      }
    }
    return true;
  }

  /// The end of the two '/' after the ':' at [colon], with any LRM and RLM
  /// before and between them, or null where none follow it.
  int? _slashesEnd(int colon) {
    var i = colon + 1;
    for (var slash = 0; slash < 2; slash++) {
      while (i < hi &&
          (text.codeUnitAt(i) == 0x200E || text.codeUnitAt(i) == 0x200F)) {
        i++;
      }
      if (i >= hi || text.codeUnitAt(i) != 0x2F) return null;
      i++;
    }
    return i;
  }

  /// Where NSDataDetector starts the scheme that ends at [sep], or null: the
  /// first ASCII letter of the run of scheme characters before it that no
  /// letter or digit precedes, or a web scheme after a '.' in the run.
  int? _schemeStart(int sep) {
    var run = sep;
    while (run > lo && _schemeChar(text.codeUnitAt(run - 1))) {
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
      return _gluedBefore(p) ? null : p;
    }
    return null;
  }

  /// The end of NSDataDetector's link for the scheme that starts at [s] and
  /// whose ':' at [sep] and slashes end at [p], or null where it reads none.
  ///
  /// The link runs to a hard or paren stop. A Cf character in its path cuts
  /// it back before its segment, or a bidi control at a segment's end ends
  /// it there, and a ZWJ ending it cuts its last segment. Before a unit of
  /// [_dropsRunBefore] it ends at [_wordEnd], and a '/' alone or an empty
  /// port's ':' goes before '"' or ZWSP. Its trailing marks go, and then
  /// its authority decides.
  int? _schemeLinkEnd(int s, int sep, int p) {
    var stop = runEnd(p);
    var authorityEnd = p;
    while (authorityEnd < stop &&
        !_isPathStart(text.codeUnitAt(authorityEnd))) {
      authorityEnd++;
    }
    final format = _formatBefore(authorityEnd, stop);
    if (format < stop) {
      final c = text.codeUnitAt(format);
      final next = format + 1 < hi ? text.codeUnitAt(format + 1) : 0x20;
      if (_bidiStop(c) &&
          (format + 1 == stop || _segmentEnd(next) || next <= 0x20)) {
        stop = format;
      } else {
        stop = _segmentBefore(format, authorityEnd);
      }
    }
    if (stop > authorityEnd &&
        text.codeUnitAt(stop - 1) == 0x200D &&
        (stop == hi || text.codeUnitAt(stop) <= 0x20)) {
      stop = _segmentBefore(stop - 1, authorityEnd);
    }
    stop = _wordEnd(p, stop, authorityEnd);
    if (authorityEnd > stop) authorityEnd = stop;
    if (stop < hi &&
        stop > p &&
        _dropsLonePath(text.codeUnitAt(stop)) &&
        (stop == authorityEnd + 1 && text.codeUnitAt(authorityEnd) == 0x2F ||
            stop == authorityEnd && text.codeUnitAt(stop - 1) == 0x3A)) {
      stop--;
      if (stop < authorityEnd) authorityEnd = stop;
    }
    final pathWord = _lastWordish(authorityEnd, stop) != null;
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
          final alone = end == p && (p == hi || _space(text.codeUnitAt(p)));
          return _onOpaqueList(s, sep) && alone ? p : null;
        }
        if (at != null && host == hostEnd && end == authorityEnd) return null;
        return end;
    }
  }

  bool _onOpaqueList(int s, int sep) =>
      opaqueSchemes.contains(text.substring(s, sep).toLowerCase());

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
    final at = _lastAt(p, authorityEnd);
    if (at != null && _hostLikeUser(s, p, at)) return _Refused();
    final host = at == null ? p : at + 1;
    int hostEnd;
    if (host < authorityEnd && text.codeUnitAt(host) == 0x5B) {
      var close = host + 1;
      while (close < authorityEnd && text.codeUnitAt(close) != 0x5D) {
        final c = text.codeUnitAt(close);
        if (_formatLike(c) && c != 0xAD || _privateUse(c)) return _Refused();
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
        if (c < 0x80) {
          if (_killsHost(c)) return _Refused();
          hostEnd++;
          continue;
        }
        if (_foreignDigit(cpAtIn(text, hostEnd, hi))) {
          var cut = _wordStart(hostEnd, host);
          while (cut > host && _isDotOrDash(text.codeUnitAt(cut - 1))) {
            cut--;
          }
          for (var i = host; i < cut; i++) {
            if (isLetterMarkDigit(cpAtIn(text, i, hi))) return _EndsAt(cut);
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

  /// Whether the userinfo from [p] to the '@' at [at] of the link that
  /// starts at [s] has a user, its part before any ':', that ends in a '.'
  /// and a label of two or three letters, under a scheme of [_webSchemes].
  bool _hostLikeUser(int s, int p, int at) {
    var user = p;
    while (user < at && text.codeUnitAt(user) != 0x3A) {
      user++;
    }
    var letters = 0;
    var i = user;
    while (i > p && isLetter(cpBeforeIn(text, i, lo))) {
      i -= width(cpBeforeIn(text, i, lo));
      letters++;
    }
    if (letters < 2 ||
        letters > 3 ||
        i <= p ||
        text.codeUnitAt(i - 1) != 0x2E) {
      return false;
    }
    final sep = text.indexOf(':', s);
    return _webSchemes.contains(text.substring(s, sep).toLowerCase());
  }

  /// NSDataDetector's reading of a scheme on the opaque list and one '/'
  /// where it reads no host after its `//` at [p] and no whitespace follows
  /// it.
  int? _schemeSlash(int s, int sep, int p) {
    if (!_onOpaqueList(s, sep) || p != sep + 3) return null;
    if (p >= hi || _space(text.codeUnitAt(p))) return null;
    return sep + 2;
  }

  /// The end of NSDataDetector's link from [s] to [end] after its trailing
  /// marks: a trimmed mark that is not the first of the run and that anything
  /// but '/' follows ends the link there; where `# - ~ *` or a '(' follows
  /// it, the run of `# - ~ *` before it goes too, and so does the mark
  /// before that run; then the trailing trimmed marks go.
  int _trailing(int s, int end) {
    final word = _lastWordish(s, end);
    final run = word == null ? s : word + 1;
    for (var i = run + 1; i < end; i++) {
      if (!_trimmed(text.codeUnitAt(i))) continue;
      final next = i + 1 < hi ? text.codeUnitAt(i + 1) : 0x20;
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
  /// the opaque list in any case, glued to no word, and a body of link
  /// characters that holds no Cf character other than the soft hyphen, ZWNJ,
  /// ZWJ, LRM and RLM, with its trailing marks and bidi controls dropped.
  (int, int)? _opaque(int colon) {
    var s = colon;
    while (s > lo && isAsciiLetter(text.codeUnitAt(s - 1))) {
      s--;
    }
    if (s == colon || !_onOpaqueList(s, colon)) return null;
    if (s > lo) {
      final before = text.codeUnitAt(s - 1);
      if (before == 0x5F ? !_isTel(s, colon) : _gluedBefore(s)) return null;
      if (isAsciiDigit(before)) return null;
    }
    final body = colon + 1;
    var stop = runEnd(body);
    while (stop > body && _bidiStop(text.codeUnitAt(stop - 1))) {
      stop--;
    }
    if (_formatBefore(body, stop) < stop) return null;
    final e = _trailing(body, _wordEnd(body, stop));
    return e == body ? null : (s, e);
  }

  /// Whether the scheme from [s] to [sep] is `tel` in any case.
  bool _isTel(int s, int sep) =>
      sep - s == 3 &&
      text.codeUnitAt(s) | 0x20 == 0x74 &&
      text.codeUnitAt(s + 1) | 0x20 == 0x65 &&
      text.codeUnitAt(s + 2) | 0x20 == 0x6C;

  /// Whether NSDataDetector's word joins the character at [i] to what
  /// precedes it: a letter or digit outside Han, kana and Hangul, or such a
  /// letter and a ':', '：' or '.', ends there, skipping marks and Cf
  /// characters other than U+200B.
  bool _gluedBefore(int i) {
    var afterMid = false;
    while (i > lo) {
      final cp = cpBeforeIn(text, i, lo);
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

  /// The start of the word that holds the character at [i], no earlier than
  /// [from]: word characters join, and a '.' joins two letters or two
  /// digits.
  int _wordStart(int i, int from) {
    var j = i;
    while (j > from) {
      final before = cpBeforeIn(text, j, lo);
      if (_hostWord(before)) {
        j -= width(before);
        continue;
      }
      if (before == 0x2E && j - 1 > from) {
        final left = cpBeforeIn(text, j - 1, lo);
        final right = cpAtIn(text, j, hi);
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
}

bool _schemeChar(int c) =>
    isAsciiLetter(c) || isAsciiDigit(c) || c == 0x2B || c == 0x2E || c == 0x2D;

/// Whether [cp] is in ICU's `\w` or Cf.
bool _wordOrFormat(int cp) => isWord(cp) || _formatLike(cp);

/// Whether the UTF-16 unit [c] is a Cf character that cuts a link's path:
/// one other than the soft hyphen, ZWNJ, ZWJ, LRM and RLM.
bool _cutsPath(int c) => c >= 0xAD && _formatLike(c) && !_keptFormat(c);

/// Whether [cp] joins a word as NSDataDetector reads one: a Hangul filler,
/// or a letter or digit outside Han, kana and Hangul.
bool _joinsWord(int cp) =>
    _isHangulFiller(cp) ||
    (isLetter(cp) || isDigit(cp)) &&
        !(cp >= 0x1100 && cp <= 0x11FF) &&
        !(cp >= 0x2E80 && cp <= 0x9FFF && !_isBopomofo(cp)) &&
        !(cp >= 0xA960 && cp <= 0xA97F) &&
        !(cp >= 0xAC00 && cp <= 0xD7FF) &&
        !(cp >= 0xF900 && cp <= 0xFAFF) &&
        !(cp >= 0xFF66 && cp <= 0xFFDC) &&
        !(cp >= 0x20000 && cp <= 0x3FFFF);

bool _isBopomofo(int cp) =>
    (cp >= 0x3100 && cp <= 0x312F) || (cp >= 0x31A0 && cp <= 0x31BF);

bool _isHangulFiller(int cp) =>
    cp == 0x115F || cp == 0x1160 || cp == 0x3164 || cp == 0xFFA0;

/// Whether the UTF-16 unit [c] ends NSDataDetector's link before it:
/// whitespace, a C0 or C1 control or DEL, `{ } < > "`, CJK punctuation,
/// ZWSP or a private-use character of [_privateUseStop].
bool _linkStop(int c) => c < 0x7F
    ? c <= 0x20 || c == 0x22 || c == 0x3C || c == 0x3E || c == 0x7B || c == 0x7D
    : c <= 0xA0 ||
          c >= 0x1680 &&
              (c == 0x1680 ||
                  (c >= 0x2000 && c <= 0x200B) ||
                  c == 0x2028 ||
                  c == 0x2029 ||
                  c == 0x202F ||
                  c == 0x205F ||
                  c == 0x3000 ||
                  _privateUseStop(c) ||
                  isCjkPunctuation(c));

/// Whether the UTF-16 unit [c] is a private-use character that ends
/// NSDataDetector's link: U+E000–U+F7F2, U+F8A1–U+F8A7, U+F8B4–U+F8B7 or
/// U+F8BB–U+F8C0.
bool _privateUseStop(int c) =>
    (c >= 0xE000 && c <= 0xF7F2) ||
    (c >= 0xF8A1 && c <= 0xF8A7) ||
    (c >= 0xF8B4 && c <= 0xF8B7) ||
    (c >= 0xF8BB && c <= 0xF8C0);

/// Whether the UTF-16 unit [c] ends NSDataDetector's link at [_Scan._wordEnd]:
/// a C0 control other than tab, LF and CR, DEL, a C1 control, '<' or a
/// private-use character of [_privateUseStop] other than U+F8B4, U+F8BE and
/// U+F8BF.
bool _dropsRunBefore(int c) =>
    (c <= 0x1F && c != 0x09 && c != 0x0A && c != 0x0D) ||
    (c >= 0x7F && c <= 0x9F) ||
    c == 0x3C ||
    _privateUseStop(c) && c != 0xF8B4 && c != 0xF8BE && c != 0xF8BF;

/// Whether the UTF-16 unit [c] is one of `/ ' ? : # - ~ * . , ! ;`, the
/// characters of a tail [_Scan._tailEnd] reads.
bool _tailChar(int c) =>
    _slashLike(c) ||
    c == 0x3F ||
    c == 0x3A ||
    _dropsBefore(c) ||
    c == 0x2E ||
    c == 0x2C ||
    c == 0x21 ||
    c == 0x3B;

bool _slashLike(int c) => c == 0x2F || c == 0x27;

/// Whether a path that is a '/' alone, or an empty port's ':', goes where the
/// UTF-16 unit [c] follows it.
bool _dropsLonePath(int c) => c == 0x22 || c == 0x200B;

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
bool _formatLike(int c) => c >= 0xAD && (isFormat(c) || c == 0x2065);

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

/// Whether the UTF-16 unit [c] in a link's host means no link.
bool _killsHost(int c) =>
    c == 0x5B ||
    c == 0x5D ||
    c == 0x60 ||
    c == 0x7C ||
    c == 0x5C ||
    c == 0x5E ||
    c >= 0xAD &&
        (c == 0x2026 ||
            _privateUse(c) ||
            _formatLike(c) && c != 0xAD && c != 0x200C && c != 0x200D);

bool _privateUse(int c) => c >= 0xE000 && c <= 0xF8FF;

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
