import 'package:ux/src/url/chars.dart';

/// A match of Patterns.EMAIL_ADDRESS: its span and its '@'.
typedef EmailAddressMatch = ({int start, int at, int end});

/// The matches of Patterns.EMAIL_ADDRESS,
/// `[a-zA-Z0-9\+\.\_\%\-\+]{1,256}\@[a-zA-Z0-9][a-zA-Z0-9\-]{0,64}(\.[a-zA-Z0-9][a-zA-Z0-9\-]{0,25})+`,
/// in [text], leftmost first, each search starting at the previous match's
/// end.
List<EmailAddressMatch> emailAddressMatches(String text) {
  final out = <EmailAddressMatch>[];
  var i = 0;
  while (true) {
    final at = text.indexOf('@', i);
    if (at < 0) return out;
    var run = at;
    while (run > i && _local(text.codeUnitAt(run - 1))) {
      run--;
    }
    final start = run < at - 256 ? at - 256 : run;
    final end = start < at ? _domainEnd(text, at + 1) : null;
    if (end == null) {
      i = at + 1;
      continue;
    }
    out.add((start: start, at: at, end: end));
    i = end;
  }
}

bool _local(int c) =>
    isAsciiLetter(c) ||
    isAsciiDigit(c) ||
    c == 0x2B ||
    c == 0x2E ||
    c == 0x5F ||
    c == 0x25 ||
    c == 0x2D;

bool _alnum(int c) => isAsciiLetter(c) || isAsciiDigit(c);

/// The end of a domain at [p]: a label of a letter or digit and up to 64
/// letters, digits and '-', then one or more of '.', a letter or digit and
/// up to 25 letters, digits and '-'.
int? _domainEnd(String text, int p) {
  final n = text.length;
  if (p >= n || !_alnum(text.codeUnitAt(p))) return null;
  var q = p + 1;
  var run = 0;
  while (q < n && run <= 64 && _labelChar(text.codeUnitAt(q))) {
    q++;
    run++;
  }
  if (run > 64) return null;
  int? end;
  while (q + 1 < n &&
      text.codeUnitAt(q) == 0x2E &&
      _alnum(text.codeUnitAt(q + 1))) {
    q += 2;
    var k = 0;
    while (k < 25 && q < n && _labelChar(text.codeUnitAt(q))) {
      q++;
      k++;
    }
    end = q;
  }
  return end;
}

bool _labelChar(int c) => _alnum(c) || c == 0x2D;
