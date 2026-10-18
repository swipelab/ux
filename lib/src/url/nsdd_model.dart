import 'package:ux/src/url/any_scheme.dart';
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
    (isLetter(cp) || isDigit(cp)) &&
    !(cp >= 0x1100 && cp <= 0x11FF) &&
    !(cp >= 0x2E80 && cp <= 0x9FFF) &&
    !(cp >= 0xA960 && cp <= 0xA97F) &&
    !(cp >= 0xAC00 && cp <= 0xD7FF) &&
    !(cp >= 0xF900 && cp <= 0xFAFF) &&
    !(cp >= 0xFF66 && cp <= 0xFFDC) &&
    !(cp >= 0x20000 && cp <= 0x3FFFF);

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
  for (final (start, end) in anySchemeMatches(text)) {
    final sep = text.indexOf('://', start);
    final s = _schemeStart(text, sep);
    if (s == null) continue;
    final e = end;
    if (e <= sep + 3) continue;
    out.add((start: s, end: e, phone: false, value: text.substring(s, e)));
  }
  return out;
}

bool _opaqueStop(int c) =>
    c <= 0x20 ||
    (c >= 0x7F && c <= 0xA0) ||
    c == 0x22 ||
    c == 0x28 ||
    c == 0x29 ||
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

/// Whether the UTF-16 unit [c] in an opaque URI's body means no link: a Cf
/// character other than the soft hyphen, ZWSP, ZWNJ, ZWJ, LRM and RLM.
bool _opaqueKill(int c) =>
    isFormat(c) && c != 0xAD && !(c >= 0x200B && c <= 0x200F);

bool _opaqueTrim(int c) =>
    c == 0x2E ||
    c == 0x2C ||
    c == 0x3B ||
    c == 0x21 ||
    c == 0x5D ||
    c == 0x2026 ||
    c == 0x201D ||
    c == 0x200C ||
    c == 0x200D ||
    (isBidiControl(c) && c != 0x200E && c != 0x200F);

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
    if (!opaqueSchemes.contains(lower)) continue;
    if (lower == 'tel' && scheme != 'tel') continue;
    if (s > 0) {
      final before = text.codeUnitAt(s - 1);
      if (before == 0x5F ? lower != 'tel' : _gluedBefore(text, s)) continue;
      if (isAsciiDigit(before)) continue;
    }
    if (text.startsWith('//', colon + 1)) continue;
    var e = colon + 1;
    while (e < text.length && !_opaqueStop(text.codeUnitAt(e))) {
      e++;
    }
    while (e > colon + 1 &&
        _opaqueTrim(text.codeUnitAt(e - 1)) &&
        !(text.codeUnitAt(e - 1) == 0x2060 ||
            text.codeUnitAt(e - 1) == 0xFEFF)) {
      e--;
    }
    if (e == colon + 1) continue;
    var killed = false;
    for (var i = colon + 1; i < e; i++) {
      if (_opaqueKill(text.codeUnitAt(i))) killed = true;
    }
    if (killed) continue;
    out.add((start: s, end: e, phone: false, value: text.substring(s, e)));
  }
  return out;
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
