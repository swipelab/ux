import 'dart:convert';

import 'package:ux/src/url/chars.dart';

/// One NSDataDetector result: a link with its URL, or a phone number with its
/// phone string.
typedef NsddResult = ({int start, int end, bool phone, String value});

/// NSDataDetector's results of [text] (`.link | .phoneNumber`), in its order,
/// as macOS 26.4 reads them under en_US.
List<NsddResult> nsddResults(String text) {
  final out = <NsddResult>[..._schemeLinks(text), ..._opaqueLinks(text)]
    ..sort((a, b) => a.start.compareTo(b.start));
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
    if (isMark(cp) || isFormat(cp) && cp != 0x200B) {
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

bool _isHangulFiller(int cp) =>
    cp == 0x115F || cp == 0x1160 || cp == 0x3164 || cp == 0xFFA0;

/// Where NSDataDetector starts the scheme that ends at [sep], or null: the
/// first ASCII letter of the run of scheme characters before it that no
/// letter or digit precedes, or a web scheme after a '.' in the run.
int? _schemeStart(String text, int sep) {
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

List<NsddResult> _schemeLinks(String text) {
  final out = <NsddResult>[];
  for (
    var sep = text.indexOf('://');
    sep >= 0;
    sep = text.indexOf('://', sep + 1)
  ) {
    final s = _schemeStart(text, sep);
    if (s == null) continue;
    final end = _schemeLinkEnd(text, s, sep) ?? _schemeSlash(text, s, sep);
    if (end == null) continue;
    out.add((start: s, end: end, phone: false, value: text.substring(s, end)));
  }
  return out;
}

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

/// Whether a path that is a '/' alone ends with its link's authority where
/// the UTF-16 unit [c] follows it.
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

/// The end of NSDataDetector's link for the `scheme://` at [sep] that starts
/// at [s], or null where it reads none.
int? _schemeLinkEnd(String text, int s, int sep) {
  final n = text.length;
  final scheme = text.substring(s, sep).toLowerCase();
  final p = sep + 3;
  var stop = p;
  while (stop < n && !_linkStop(text.codeUnitAt(stop))) {
    stop++;
  }
  stop = _parenStop(text, p, stop);
  var authorityEnd = p;
  while (authorityEnd < stop && !_isPathStart(text.codeUnitAt(authorityEnd))) {
    authorityEnd++;
  }
  for (var i = authorityEnd; i < stop; i++) {
    final c = text.codeUnitAt(i);
    if (!isFormat(c) || _keptFormat(c)) continue;
    if (c == 0x200D) continue;
    final next = i + 1 < n ? text.codeUnitAt(i + 1) : 0x20;
    final atEnd = i + 1 == stop || _segmentEnd(next) || next <= 0x20;
    if (_bidiStop(c) && atEnd) {
      stop = i;
      break;
    }
    var cut = i;
    while (cut > authorityEnd && !_segmentEnd(text.codeUnitAt(cut - 1))) {
      cut--;
    }
    stop = cut > authorityEnd ? cut - 1 : authorityEnd;
    break;
  }
  if (stop > authorityEnd &&
      text.codeUnitAt(stop - 1) == 0x200D &&
      (stop == n || text.codeUnitAt(stop) <= 0x20)) {
    var cut = stop - 1;
    while (cut > authorityEnd && !_segmentEnd(text.codeUnitAt(cut - 1))) {
      cut--;
    }
    stop = cut > authorityEnd ? cut - 1 : authorityEnd;
  }
  if (stop == authorityEnd + 1 &&
      text.codeUnitAt(authorityEnd) == 0x2F &&
      stop < n &&
      _dropsLonePath(text.codeUnitAt(stop))) {
    stop = authorityEnd;
  }
  final end = _trailing(text, s, stop);
  if (authorityEnd > end) authorityEnd = end;
  final at = text.lastIndexOf('@', authorityEnd - 1);
  final host = at >= p ? at + 1 : p;
  int hostEnd;
  if (host < authorityEnd && text.codeUnitAt(host) == 0x5B) {
    final close = text.indexOf(']', host);
    if (close < 0 || close >= authorityEnd) return null;
    for (var i = host + 1; i < close; i++) {
      final c = text.codeUnitAt(i);
      if (isFormat(c) && !_isHangulFiller(c)) return null;
    }
    hostEnd = close + 1;
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
          if (isLetterMarkDigit(cpAt(text, i))) return cut;
        }
        return null;
      }
      if (_bidiStop(c) && hostEnd + 1 == authorityEnd && hostEnd > host) {
        return _trailing(text, s, hostEnd);
      }
      if (_killsHost(c)) return null;
      hostEnd++;
    }
    while (hostEnd > host && text.codeUnitAt(hostEnd - 1) == 0x200C) {
      hostEnd--;
    }
  }
  if (hostEnd < authorityEnd) {
    if (text.codeUnitAt(hostEnd) != 0x3A) return null;
    var d = hostEnd + 1;
    while (d < authorityEnd && _portChar(text.codeUnitAt(d))) {
      d++;
    }
    if (d < authorityEnd) {
      final c = text.codeUnitAt(d);
      if (isDigit(c) || (isFormat(c) && !(c >= 0x200C && c <= 0x200F))) {
        return _trailing(text, s, hostEnd);
      }
      return null;
    }
  }
  if (host == hostEnd &&
      at < p &&
      hostEnd == authorityEnd &&
      end == authorityEnd) {
    final alone = end == p && (p == n || _space(text.codeUnitAt(p)));
    return opaqueSchemes.contains(scheme) && alone ? p : null;
  }
  if (at >= p && host == hostEnd && end == authorityEnd) return null;
  return end;
}

bool _isPathStart(int c) => c == 0x2F || c == 0x3F || c == 0x23;

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
    isFormat(c) && c != 0xAD && c != 0x200C && c != 0x200D;

/// Whether the UTF-16 unit [c] is a port character: an ASCII or fullwidth
/// digit, or a Cf character NSDataDetector keeps in a port.
bool _portChar(int c) =>
    _portDigit(c) || c == 0xAD || c == 0x034F || c == 0x3164 || c == 0xFE0F;

/// NSDataDetector's reading of a scheme on the opaque list and one '/' where
/// it reads no host after its `//` and no whitespace follows it.
int? _schemeSlash(String text, int s, int sep) {
  if (!opaqueSchemes.contains(text.substring(s, sep).toLowerCase())) {
    return null;
  }
  final p = sep + 3;
  if (p >= text.length || _space(text.codeUnitAt(p))) return null;
  return sep + 2;
}

bool _space(int c) => c == 0x0B || isIcuSpace(c);

bool _portDigit(int c) => isAsciiDigit(c) || (c >= 0xFF10 && c <= 0xFF19);

/// Where a '(' that no ')' after it closes, or a ')' that no '(' before it
/// opens, between [p] and [stop] ends NSDataDetector's link.
int _parenStop(String text, int p, int stop) {
  var lastClose = -1;
  for (var i = stop - 1; i >= p; i--) {
    if (text.codeUnitAt(i) == 0x29) {
      lastClose = i;
      break;
    }
  }
  var opened = false;
  for (var i = p; i < stop; i++) {
    final c = text.codeUnitAt(i);
    if (c == 0x28) {
      if (lastClose < i) return i;
      opened = true;
    } else if (c == 0x29 && !opened) {
      return i;
    }
  }
  return stop;
}

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

/// The end of NSDataDetector's link from [s] to [end] after its trailing
/// marks: a trimmed mark that is not the first of the run and that anything
/// but '/' follows ends the link there, dropping the character before it
/// too, and the run of `# - ~ *` before that, where `# - ~ *` follows it;
/// then the trailing trimmed marks go.
int _trailing(String text, int s, int end) {
  var run = end;
  while (run > s && !_wordish(text.codeUnitAt(run - 1))) {
    run--;
  }
  for (var i = run + 1; i < end; i++) {
    if (!_trimmed(text.codeUnitAt(i))) continue;
    final next = i + 1 < text.length ? text.codeUnitAt(i + 1) : 0x20;
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

List<NsddResult> _opaqueLinks(String text) {
  final out = <NsddResult>[];
  for (
    var colon = text.indexOf(':');
    colon >= 0;
    colon = text.indexOf(':', colon + 1)
  ) {
    var s = colon;
    while (s > 0 && isAsciiLetter(text.codeUnitAt(s - 1))) {
      s--;
    }
    if (s == colon) continue;
    final scheme = text.substring(s, colon);
    final lower = scheme.toLowerCase();
    final mailto = lower == 'mailto';
    if (!mailto && !opaqueSchemes.contains(lower)) continue;
    if (lower == 'tel' && scheme != 'tel') continue;
    if (s > 0) {
      final before = text.codeUnitAt(s - 1);
      if (before == 0x5F ? lower != 'tel' : _gluedBefore(text, s)) continue;
      if (isAsciiDigit(before)) continue;
    }
    if (text.startsWith('//', colon + 1)) continue;
    final body = colon + 1;
    var stop = body;
    while (stop < text.length && !_linkStop(text.codeUnitAt(stop))) {
      stop++;
    }
    stop = _parenStop(text, body, stop);
    while (stop > body && _bidiStop(text.codeUnitAt(stop - 1))) {
      stop--;
    }
    var killed = false;
    for (var i = body; i < stop; i++) {
      final c = text.codeUnitAt(i);
      if (isFormat(c) && !_keptFormat(c)) killed = true;
    }
    if (killed) continue;
    final e = _trailing(text, body, stop);
    if (e == body) continue;
    if (mailto && !_mailtoAddress(text, body, e)) continue;
    out.add((
      start: s,
      end: e,
      phone: false,
      value: mailto ? _escaped(text.substring(s, e)) : text.substring(s, e),
    ));
  }
  return out;
}

/// Whether [body, end) of [text], a `mailto:` URI's body, holds an address
/// NSDataDetector reads: before any '?', a local part and a domain of
/// labels of ASCII letters, digits, '-' and '_' joined by single dots whose
/// last label is letters, or a body that is a query alone.
bool _mailtoAddress(String text, int body, int end) {
  var q = body;
  while (q < end && text.codeUnitAt(q) != 0x3F) {
    q++;
  }
  if (q == body) {
    final at = text.indexOf('@', body);
    return at >= 0 && at < end;
  }
  final at = text.lastIndexOf('@', q - 1);
  if (at <= body) return false;
  final labels = text.substring(at + 1, q).split('.');
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
const nsddBareTldList = [
  'ae', 'ai', 'ar', 'at', 'au', 'be', 'bg', 'bid', 'biz', 'bo', 'br', 'bs', //
  'ca', 'cc', 'ch', 'cl', 'club', 'cm', 'cn', 'co', 'com', 'cx', 'cz', 'de',
  'dk', 'edu', 'ee', 'es', 'eu', 'fi', 'fm', 'fr', 'gdn', 'gl', 'google',
  'gov', 'gr', 'hk', 'hn', 'hr', 'hu', 'id', 'ie', 'il', 'in', 'info', 'io',
  'ir', 'is', 'it', 'jo', 'jp', 'kr', 'la', 'lc', 'li', 'link', 'lk', 'loan',
  'lt', 'lu', 'lv', 'ly', 'ma', 'me', 'ms', 'mx', 'my', 'net', 'nl', 'no',
  'nz', 'online', 'org', 'ph', 'pk', 'pl', 'pn', 'pt', 'pw', 'ro', 'rs', 'ru',
  'sa', 'se', 'sg', 'si', 'site', 'sk', 'so', 'social', 'st', 'tech', 'th',
  'tm', 'tn', 'to', 'tr', 'tt', 'tv', 'tw', 'ua', 'uk', 'us', 'uy', 'va',
  'vip', 'vn', 'wang', 'win', 'xin', 'xyz', 'za',
  'рус',
  'рф',
  'укр',
  'السعودية',
  'امارات',
  'مصر',
  'مليسيا',
  'भारत',
  'ਭਾਰਤ',
  'ભારત',
  'ไทย',
  '한국',
];

/// [nsddBareTldList] as a set.
final nsddBareTlds = nsddBareTldList.toSet();
