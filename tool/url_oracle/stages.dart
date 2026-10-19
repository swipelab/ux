// Darwin's stages after its candidates: url_detect.mm's sort, de-overlap and
// continuation cut (stage 3), and the oracle commit's lib/src/url.dart over
// the native buffer (stages 1 and 4 to 7).
import 'wire.dart';

/// url_detect.mm's kinds in its sort order, web lowest.
const kindOrder = {'web': 0, 'email': 1, 'phone': 2};

/// What stage 3 keeps of [candidates], and the fullwidth '(' of each cut it
/// sets, by the sorted position it sets it at.
typedef Deduped = ({List<Link> kept, List<(int, int)> cuts});

/// url_detect.mm's stage 3 over [candidates] of [text]: sort by start, then
/// length descending, then phone, email, web; then walk that order, skipping
/// a web candidate that continues the path of the current cut ([everyKind]
/// widens the skip to every kind), setting the cut at a web candidate whose
/// path runs on to a fullwidth '(', and dropping a candidate that starts
/// before the last kept end.
Deduped stage3(String text, List<Link> candidates, {bool everyKind = false}) {
  final order = [for (var i = 0; i < candidates.length; i++) i]
    ..sort((x, y) {
      final a = candidates[x];
      final b = candidates[y];
      if (a.start != b.start) return a.start.compareTo(b.start);
      final la = a.end - a.start;
      final lb = b.end - b.start;
      if (la != lb) return lb.compareTo(la);
      final ka = kindOrder[a.kind]!;
      final kb = kindOrder[b.kind]!;
      if (ka != kb) return kb.compareTo(ka);
      return x.compareTo(y);
    });
  final kept = <Link>[];
  final cuts = <(int, int)>[];
  var lastEnd = 0;
  var any = false;
  int? cut;
  for (var n = 0; n < order.length; n++) {
    final m = candidates[order[n]];
    if (m.kind == 'web' || everyKind) {
      if (cut != null && continuesPath(text, cut, m.start, m.end)) continue;
    }
    if (m.kind == 'web') {
      final paren = pathParen(text, m.start, m.end);
      if (paren != null) {
        cut = paren;
        cuts.add((n, paren));
      }
    }
    if (any && m.start < lastEnd) continue;
    kept.add(m);
    lastEnd = m.end;
    any = true;
  }
  return (kept: kept, cuts: cuts);
}

/// ux_path_start: the first '/', '?' or '#' of the web match [start, end)
/// past the "//" that follows a scheme.
int pathStart(String text, int start, int end) {
  var i = start;
  while (i < end && !':/?#'.contains(text[i])) {
    i++;
  }
  if (i + 2 < end &&
      text[i] == ':' &&
      text[i + 1] == '/' &&
      text[i + 2] == '/') {
    i += 3;
  }
  while (i < end && !'/?#'.contains(text[i])) {
    i++;
  }
  return i;
}

bool _isHex(int c) =>
    (c >= 0x30 && c <= 0x39) ||
    (c >= 0x61 && c <= 0x66) ||
    (c >= 0x41 && c <= 0x46);

/// ux_is_ucs_char: whether [c] is in Patterns.WEB_URL's UCS_CHAR.
bool isUcsChar(int c) {
  if (c > 0xFFFF) {
    return (c & 0xFFFF) <= 0xFFFD &&
        c < 0xF0000 &&
        !(c >= 0xE0000 && c < 0xE1000);
  }
  return ((c > 0xA0 && c <= 0xD7FF) ||
          (c >= 0xF900 && c <= 0xFDCF) ||
          (c >= 0xFDF0 && c <= 0xFFEF)) &&
      !((c >= 0x2000 && c <= 0x200A) ||
          c == 0x2028 ||
          c == 0x2029 ||
          c == 0x202F ||
          c == 0x3000);
}

/// ux_path_mark: the first character in [i, end) that Patterns.WEB_URL's path
/// does not take, or [end].
int pathMark(String text, int i, int end) {
  while (i < end) {
    final c = text.codeUnitAt(i);
    var next = i + 1;
    bool mark;
    if (c == 0x25) {
      mark =
          !(i + 2 < end &&
              _isHex(text.codeUnitAt(i + 1)) &&
              _isHex(text.codeUnitAt(i + 2)));
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

/// ux_is_cjk_punctuation, by UTF-16 unit.
bool isCjkPunctuation(int c) =>
    (c >= 0x3001 && c <= 0x3003) ||
    (c >= 0x3008 && c <= 0x3011) ||
    (c >= 0x3014 && c <= 0x301F) ||
    (c >= 0xFE10 && c <= 0xFE19) ||
    (c >= 0xFE30 && c <= 0xFE6B) ||
    (c >= 0xFF01 && c <= 0xFF0F) ||
    (c >= 0xFF1A && c <= 0xFF20) ||
    (c >= 0xFF3B && c <= 0xFF40) ||
    (c >= 0xFF5B && c <= 0xFF65);

/// ux_path_paren: the fullwidth '(' that ends the stretch between CJK
/// punctuation the web match [start, end) ends in, where its path runs on to
/// it.
int? pathParen(String text, int start, int end) {
  if (pathStart(text, start, end) == end) return null;
  var paren = end;
  while (paren < text.length && !isCjkPunctuation(text.codeUnitAt(paren))) {
    paren++;
  }
  if (paren == text.length ||
      text.codeUnitAt(paren) != 0xFF08 ||
      pathMark(text, end, paren) < paren) {
    return null;
  }
  return paren;
}

/// ux_continues_path: whether the web match [start, end) continues the path
/// that runs on to the fullwidth '(' at [paren].
bool continuesPath(String text, int paren, int start, int end) {
  if (start <= paren) return false;
  var from = start;
  while (!isCjkPunctuation(text.codeUnitAt(from - 1))) {
    from--;
  }
  if (text.codeUnitAt(from - 1) != 0xFF09) return false;
  while (from < start && !'/?#&='.contains(text[from])) {
    from++;
  }
  return from < start && pathMark(text, paren, end) == end;
}

/// ux_web_end: the end of the web match [start, end) before the first
/// character its path does not take, then before a trailing '.', ',', ';',
/// '!', '\'' or '(' and a trailing ')' it does not open.
int webEnd(String text, int start, int end) {
  end = pathMark(text, pathStart(text, start, end), end);
  var unopened = 0;
  for (var i = start; i < end; i++) {
    if (text[i] == ')') unopened++;
    if (text[i] == '(') unopened--;
  }
  while (end > start) {
    final c = text[end - 1];
    if (c == ')' && unopened > 0) {
      unopened--;
    } else if (c == '(') {
      unopened++;
    } else if (!".,;!'".contains(c)) {
      break;
    }
    end--;
  }
  return end;
}

/// Stage 1, `_hasSigil`: whether [text] holds a '.', ':', '@' or '+', or five
/// ASCII digits.
bool hasSigil(String text) {
  var digits = 0;
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (c == 0x2E || c == 0x3A || c == 0x40 || c == 0x2B) return true;
    if (c >= 0x30 && c <= 0x39) {
      digits++;
      if (digits >= 5) return true;
    }
  }
  return false;
}

/// Whether [c] is one of Unicode's Bidi_Control characters.
bool isBidiControl(int c) =>
    c == 0x061C ||
    c == 0x200E ||
    c == 0x200F ||
    (c >= 0x202A && c <= 0x202E) ||
    (c >= 0x2066 && c <= 0x2069);

/// `_keepBidiControls`: [url], or its scheme and the link's text where that
/// text holds a bidi control [url] leaves out.
String keepBidiControls(String url, String text, int start, int end) {
  if (url.codeUnits.any(isBidiControl)) return url;
  final linked = text.substring(start, end);
  if (!linked.codeUnits.any(isBidiControl)) return url;
  final scheme = url.substring(0, url.indexOf(':') + 1).toLowerCase();
  return linked.toLowerCase().startsWith(scheme) ? linked : '$scheme$linked';
}

/// Whether `_sanitizeUrl` leaves the UTF-16 unit [c] out of a URL: tab, LF,
/// CR, NBSP, ZWSP, ZWNJ, ZWJ, U+2060–U+2065, U+206A–U+206F and U+FEFF.
bool sanitizeStrips(int c) =>
    c == 0x09 ||
    c == 0x0A ||
    c == 0x0D ||
    c == 0xA0 ||
    (c >= 0x200B && c <= 0x200D) ||
    (c >= 0x2060 && c <= 0x2065) ||
    (c >= 0x206A && c <= 0x206F) ||
    c == 0xFEFF;

/// `_sanitizeUrl`: [url] without the units [sanitizeStrips] holds.
String sanitizeUrl(String url) =>
    String.fromCharCodes(url.codeUnits.where((c) => !sanitizeStrips(c)));

/// The links stage 4 keeps of stage 3's: the first 64.
const maxNativeLinks = 64;

/// The native links of [buffer] as `_decode` gives them for [text]: the first
/// [cap], each URL with its bidi controls kept and sanitized.
List<Link> decodeNative(
  List<Link> buffer,
  String text, {
  int cap = maxNativeLinks,
}) => [
  for (final m in buffer.take(cap < 0 ? 0 : cap))
    Link(
      m.start,
      m.end,
      m.kind,
      sanitizeUrl(keepBidiControls(m.url, text, m.start, m.end)),
    ),
];

/// `_tightenPhoneMatches`: [links] without a phone that no whitespace
/// precedes or whose first character is no '(', '+' or '0'.
List<Link> tightenPhones(List<Link> links, String text) => [
  for (final m in links)
    if (m.kind != 'phone' ||
        (_phoneLeftBoundaryOk(text, m.start) &&
            _phoneLeadingCharOk(text, m.start, m.end)))
      m,
];

bool _phoneLeftBoundaryOk(String text, int start) {
  if (start <= 0) return true;
  final c = text.codeUnitAt(start - 1);
  return c == 0x20 ||
      c == 0x09 ||
      c == 0x0A ||
      c == 0x0D ||
      c == 0xA0 ||
      c == 0x3000 ||
      c == 0x2028 ||
      c == 0x2029;
}

bool _phoneLeadingCharOk(String text, int start, int end) {
  final hi = end > text.length ? text.length : end;
  final lo = start < 0 ? 0 : start;
  if (lo >= hi) return false;
  final first = text.codeUnitAt(lo);
  return first == 0x28 || first == 0x2B || first == 0x30;
}

/// `_kAnySchemeRegex` at the oracle commit.
final anySchemeRegex = RegExp(
  r'(?<![a-zA-Z0-9+.\-])([0-9+.\-]*)[a-zA-Z][a-zA-Z0-9+.\-]*://'
  '(?:(?:[^$_urlEnd/?#]|%[0-9a-fA-F]{2})*@)?'
  '(?:\\[[0-9a-fA-F:.]+\\]'
  '|(?:$_hostChar|\\((?:$_hostChar|\\($_hostChar*\\))*\\))*)'
  r'(?::[0-9]+\b|:(?=[/?#]))?'
  '(?:[/?#]$_urlChar*)?',
);

const String _urlChar = '(?:[^$_urlEnd]|%[0-9a-fA-F]{2})';

const String _hostChar = '(?:[^$_urlEnd/?#:@()]|%[0-9a-fA-F]{2})';

const String _urlEnd =
    r'\s\x00-\x1F\x7F-\x9F"%<>\[\\\]^`{|}'
    r'、-〃〈-】〔-〟︐-︙︰-﹫'
    r'！-／：-＠［-｀｛-･';

/// `_trimUrlTrailingPunctuation`: the end of the any-scheme link [start, end)
/// before a trailing `.`, `,`, `;`, `!`, `'` or `(`, and before a `)` it does
/// not open that only these marks, `)`, `?` and `:` follow.
int trimAnyScheme(String text, int start, int end) {
  var unopened = 0;
  for (var i = start; i < end; i++) {
    final c = text.codeUnitAt(i);
    if (c == 0x29) unopened++;
    if (c == 0x28) unopened--;
  }
  var kept = end;
  for (var i = end; i > start; i--) {
    final c = text.codeUnitAt(i - 1);
    if (c == 0x29 && unopened > 0) {
      unopened--;
      kept = i - 1;
    } else if (c == 0x28 ||
        c == 0x2E ||
        c == 0x2C ||
        c == 0x3B ||
        c == 0x21 ||
        c == 0x27) {
      if (c == 0x28) unopened++;
      if (kept == i) kept--;
    } else if (!(c == 0x3F || c == 0x3A)) {
      break;
    }
  }
  return kept;
}

/// Whether the link [start, end) of [text] is a scheme and its `://` alone.
bool schemeOnly(String text, int start, int end) =>
    end == text.indexOf('://', start) + 3;

/// The any-scheme pass's links of [text], trimmed, without a scheme and its
/// `://` alone, and sanitized.
List<Link> anySchemeLinks(String text) {
  if (!text.contains('://')) return const [];
  return [
    for (final m in anySchemeRegex.allMatches(text))
      ?anySchemeLink(text, m.start + m[1]!.length, m.end),
  ];
}

/// The any-scheme link of [text] from [start] to the match end [end], after
/// its trim, or null where only its scheme and `://` remain.
Link? anySchemeLink(String text, int start, int end) {
  final kept = trimAnyScheme(text, start, end);
  if (schemeOnly(text, start, kept)) return null;
  return Link(start, kept, 'web', sanitizeUrl(text.substring(start, kept)));
}

/// `_dedupeMatches`: sort by start, longer first, then kind index
/// descending, and drop a link that starts inside the last kept one.
List<Link> dedupe(List<Link> links) {
  links.sort((a, b) {
    if (a.start != b.start) return a.start.compareTo(b.start);
    final lenA = a.end - a.start;
    final lenB = b.end - b.start;
    if (lenA != lenB) return lenB.compareTo(lenA);
    return kindOrder[b.kind]!.compareTo(kindOrder[a.kind]!);
  });
  final out = <Link>[];
  var lastEnd = 0;
  var any = false;
  for (final m in links) {
    if (any && m.start < lastEnd) continue;
    out.add(m);
    lastEnd = m.end;
    any = true;
  }
  return out;
}

/// Stages 4 to 7 over [native] of [text], the stage-3 links: the cap of
/// [cap], the URLs' bidi controls and sanitizing, the phone filter, then the
/// merge with [anyScheme], the any-scheme pass's links.
List<Link> finish(
  String text,
  List<Link> native,
  List<Link> anyScheme, {
  int cap = maxNativeLinks,
}) {
  final links = tightenPhones(decodeNative(native, text, cap: cap), text);
  if (!text.contains('://') || anyScheme.isEmpty) return links;
  return dedupe([...links, ...anyScheme]);
}

/// The oracle commit's XUrl.match of [text] over its native [buffer].
List<Link> darwinMatch(String text, List<Link> buffer) {
  if (text.isEmpty || !hasSigil(text)) return const [];
  return finish(text, buffer, anySchemeLinks(text));
}
