import 'package:ux/src/url/any_scheme.dart';
import 'package:ux/src/url/chars.dart';
import 'package:ux/src/url/email.dart';
import 'package:ux/src/url/match.dart';
import 'package:ux/src/url/reading.dart';

/// The UTF-16 units a text reads up to (p1).
const inputBound = 4096;

/// The links of [text], sorted by [UrlMatch.start] and non-overlapping, with
/// UTF-16 offsets.
///
/// Each token, a run of units other than tab, LF, FF, CR and space, that
/// holds a link trigger reads alone in its window; a text of more than
/// [inputBound] units reads up to its last of those units at or before its
/// [inputBound]th. The first [maxNativeLinks] native links of the tokens
/// are kept, and the any-scheme pass's links join them.
List<UrlMatch> detectLinks(String text) {
  final n = text.length > inputBound ? boundOf(text) : text.length;
  final out = <UrlMatch>[];
  var kept = 0;
  var i = _nextTrigger(text, 0, n);
  while (i != null) {
    var start = i;
    while (start > 0 && !endsToken(text.codeUnitAt(start - 1))) {
      start--;
    }
    var end = i + 1;
    while (end < n && !endsToken(text.codeUnitAt(end))) {
      end++;
    }
    final (:native, :any) = readToken(text, n, start, end, kept);
    final room = maxNativeLinks - kept;
    kept += native.length;
    for (final l in dedupe([...native.take(room < 0 ? 0 : room), ...any])) {
      out.add(_match(text, l));
    }
    i = _nextTrigger(text, end, n);
  }
  return out;
}

/// The first link trigger of [text] at or after [from] and before [n].
int? _nextTrigger(String text, int from, int n) {
  for (var i = from; i < n; i++) {
    final c = text.codeUnitAt(i);
    if ((c == 0x2E || c == 0x3A) && triggerAt(text, i, n)) return i;
  }
  return null;
}

/// Whether the UTF-16 unit [c] ends a token: tab, LF, FF, CR or space.
bool endsToken(int c) => c == 0x20 || (c >= 0x09 && c <= 0x0D && c != 0x0B);

/// p1: the units of [text], longer than [inputBound], that it reads: those
/// before its last tab, LF, FF, CR or space at or before its [inputBound]th
/// unit.
int boundOf(String text) {
  for (var w = inputBound - 1; w >= 0; w--) {
    if (endsToken(text.codeUnitAt(w))) return w;
  }
  return 0;
}

/// Whether the '.' or ':' at [i] of [text], whose readable units end at
/// [n], is a link trigger: a '.' between a label unit (an ASCII letter,
/// digit, '-' or '_', or a non-ASCII unit) and an ASCII letter or digit or a
/// non-ASCII unit; a ':' after scheme characters that hold an ASCII letter
/// and before a unit above U+0020 outside U+007F–U+00A0.
bool triggerAt(String text, int i, int n) {
  if (i == 0 || i + 1 >= n) return false;
  final next = text.codeUnitAt(i + 1);
  if (text.codeUnitAt(i) == 0x2E) {
    final before = text.codeUnitAt(i - 1);
    return (before >= 0x80 ||
            isAsciiLetter(before) ||
            isAsciiDigit(before) ||
            before == 0x2D ||
            before == 0x5F) &&
        (next >= 0x80 || isAsciiLetter(next) || isAsciiDigit(next));
  }
  if (next <= 0x20 || (next >= 0x7F && next <= 0xA0)) return false;
  for (var j = i - 1; j >= 0; j--) {
    final c = text.codeUnitAt(j);
    if (isAsciiLetter(c)) return true;
    if (!(isAsciiDigit(c) || c == 0x2B || c == 0x2E || c == 0x2D)) {
      return false;
    }
  }
  return false;
}

/// [l] as a match of [text]: its URL finished as stage 5 finishes it.
UrlMatch _match(String text, Link l) => UrlMatch(
  start: l.start,
  end: l.end,
  url: sanitizeUrl(switch (l.source) {
    Source.email => emailUrl(text, l.email),
    Source.anyScheme => text.substring(l.start, l.end),
    Source.bare => 'http://${_folded(text, l.start, l.end)}',
    Source.nsdd || Source.written => _folded(text, l.start, l.end),
  }),
  kind: l.kind,
);

/// The text from [start] to [end] with the fullwidth digits of the port that
/// ends its authority as ASCII digits.
String _folded(String text, int start, int end) {
  var authority = start;
  if (isAsciiLetter(text.codeUnitAt(start))) {
    var i = start + 1;
    while (i < end && _schemeRest(text.codeUnitAt(i))) {
      i++;
    }
    if (i + 3 <= end && text.startsWith('://', i)) authority = i + 3;
  }
  var authorityEnd = authority;
  while (authorityEnd < end) {
    final c = text.codeUnitAt(authorityEnd);
    if (c == 0x2F || c == 0x3F || c == 0x23) break;
    authorityEnd++;
  }
  var port = authorityEnd;
  var fullwidth = false;
  while (port > start) {
    final c = text.codeUnitAt(port - 1);
    if (_fullwidthDigit(c)) {
      fullwidth = true;
    } else if (!isAsciiDigit(c)) {
      break;
    }
    port--;
  }
  if (!fullwidth || port == start || text.codeUnitAt(port - 1) != 0x3A) {
    return text.substring(start, end);
  }
  final out = StringBuffer(text.substring(start, port));
  for (var i = port; i < authorityEnd; i++) {
    final c = text.codeUnitAt(i);
    out.writeCharCode(_fullwidthDigit(c) ? c - 0xFF10 + 0x30 : c);
  }
  return (out..write(text.substring(authorityEnd, end))).toString();
}

bool _fullwidthDigit(int u) => u >= 0xFF10 && u <= 0xFF19;

bool _schemeRest(int c) =>
    isAsciiLetter(c) || isAsciiDigit(c) || c == 0x2B || c == 0x2E || c == 0x2D;
