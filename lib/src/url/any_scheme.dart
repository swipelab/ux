import 'package:ux/src/url/chars.dart';

/// The any-scheme pass's links in the text [text] holds from [lo] to [hi],
/// read as a text of its own, whose '://' falls from [from] to [to]: each
/// `scheme://` link from the first letter of its scheme characters, trimmed,
/// without a scheme and its `://` alone, as their spans.
///
/// A match takes the run of scheme characters before a `://` that no scheme
/// character precedes, any userinfo through its last '@' before a '/', '?',
/// '#' or a character that ends the match, a bracketed IP literal or a host
/// of characters and parenthesis pairs at most two deep, a port of ASCII
/// digits that no ASCII word character follows or a ':' that '/', '?' or '#'
/// follows, and a path of characters and '%XX' escapes after a '/', '?' or
/// '#'.
List<(int, int)> anySchemeLinks(String text, int lo, int hi, int from, int to) {
  List<(int, int)>? out;
  var after = lo;
  for (var sep = from; sep < to; sep++) {
    if (text.codeUnitAt(sep) != 0x3A ||
        sep < after ||
        sep + 3 > hi ||
        text.codeUnitAt(sep + 1) != 0x2F ||
        text.codeUnitAt(sep + 2) != 0x2F) {
      continue;
    }
    var run = sep;
    while (run > lo && _schemeChar(text.codeUnitAt(run - 1))) {
      run--;
    }
    var letter = run;
    while (letter < sep && !isAsciiLetter(text.codeUnitAt(letter))) {
      letter++;
    }
    if (run < after || letter == sep) continue;
    final end = _matchEnd(text, sep + 3, hi);
    final kept = trimAnyScheme(text, letter, end);
    if (kept != sep + 3) (out ??= []).add((letter, kept));
    after = end;
  }
  return out ?? const [];
}

bool _schemeChar(int c) =>
    isAsciiLetter(c) || isAsciiDigit(c) || c == 0x2B || c == 0x2E || c == 0x2D;

/// Whether the UTF-16 unit [c] ends an any-scheme match: Dart's `\s`, a C0
/// or C1 control or DEL, `" % < > [ \ ] ^ ` { | }` or CJK punctuation.
bool _ends(int c) => c < 0x80
    ? c <= 0x20 || c == 0x7F || c == 0x25 || isPathStop(c)
    : c <= 0x9F || isDartSpace(c) || isCjkPunctuation(c);

bool _escape(String text, int i, int hi) =>
    i + 2 < hi &&
    text.codeUnitAt(i) == 0x25 &&
    isHex(text.codeUnitAt(i + 1)) &&
    isHex(text.codeUnitAt(i + 2));

bool _authorityEnd(int c) => c == 0x2F || c == 0x3F || c == 0x23;

/// The length of the host character or '%XX' escape at [i], null where none
/// is there.
int? _hostChar(String text, int i, int hi) {
  if (i >= hi) return null;
  if (_escape(text, i, hi)) return 3;
  final c = text.codeUnitAt(i);
  if (_ends(c) ||
      _authorityEnd(c) ||
      c == 0x3A ||
      c == 0x40 ||
      c == 0x28 ||
      c == 0x29) {
    return null;
  }
  return 1;
}

/// The end of a run of host characters and parenthesis pairs that [depth]
/// more levels may nest in, from [i].
int _hostRun(String text, int i, int hi, int depth) {
  while (true) {
    final n = _hostChar(text, i, hi);
    if (n != null) {
      i += n;
    } else if (depth > 0 && i < hi && text.codeUnitAt(i) == 0x28) {
      final close = _hostRun(text, i + 1, hi, depth - 1);
      if (close >= hi || text.codeUnitAt(close) != 0x29) return i;
      i = close + 1;
    } else {
      return i;
    }
  }
}

int _matchEnd(String text, int p, int n) {
  var q = p;
  int? at;
  while (q < n) {
    if (_escape(text, q, n)) {
      q += 3;
      continue;
    }
    final c = text.codeUnitAt(q);
    if (_ends(c) || _authorityEnd(c)) break;
    if (c == 0x40) at = q;
    q++;
  }
  final host = at == null ? p : at + 1;
  var end = host;
  if (host < n && text.codeUnitAt(host) == 0x5B) {
    var r = host + 1;
    while (r < n && _literalChar(text.codeUnitAt(r))) {
      r++;
    }
    if (r > host + 1 && r < n && text.codeUnitAt(r) == 0x5D) end = r + 1;
  } else {
    end = _hostRun(text, host, n, 2);
  }
  if (end < n && text.codeUnitAt(end) == 0x3A) {
    var d = end + 1;
    while (d < n && isAsciiDigit(text.codeUnitAt(d))) {
      d++;
    }
    if (d > end + 1 && (d == n || !_asciiWord(text.codeUnitAt(d)))) {
      end = d;
    } else if (end + 1 < n && _authorityEnd(text.codeUnitAt(end + 1))) {
      end++;
    }
  }
  if (end < n && _authorityEnd(text.codeUnitAt(end))) {
    end++;
    while (end < n) {
      final c = text.codeUnitAt(end);
      if (c == 0x25) {
        if (!_escape(text, end, n)) break;
        end += 3;
      } else if (_ends(c)) {
        break;
      } else {
        end++;
      }
    }
  }
  return end;
}

bool _literalChar(int c) => isHex(c) || c == 0x3A || c == 0x2E;

bool _asciiWord(int c) => isAsciiLetter(c) || isAsciiDigit(c) || c == 0x5F;

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
String sanitizeUrl(String url) {
  for (var i = 0; i < url.length; i++) {
    if (sanitizeStrips(url.codeUnitAt(i))) {
      return String.fromCharCodes(
        url.codeUnits.where((c) => !sanitizeStrips(c)),
      );
    }
  }
  return url;
}
