import 'package:ux/src/url/chars.dart';
import 'package:ux/src/url/tld.dart';
import 'package:ux/src/url/web_pass.dart';

/// An email R5 reads: its span, its '@', and whether a written `mailto:`
/// starts it.
typedef Email = ({int start, int at, int end, bool mailto});

/// R5's emails of the text [text] holds from [lo] to [hi], read as a text of
/// its own, at each '@' from [from] to [to].
///
/// The local part is the run of EMAIL_ADDRESS's local class before the '@',
/// at most 256 of its characters; the domain is two or more ASCII labels of
/// letters and digits with inner '-' or '_', joined by single dots, whose
/// last label is a TLD in any case. A Bidi_Control between two of the
/// email's characters stays in it. A `mailto:` in any case before the local
/// part, with only Bidi_Controls between, joins the email where no ASCII
/// letter, digit or '_' precedes it, and such an email keeps a query: a '?'
/// and R1's body after it, which ends as a path ends, and a '?' that no body
/// character stays after goes.
List<Email> emailsOf(String text, int lo, int hi, int from, int to) {
  final out = <Email>[];
  var lastEnd = lo;
  for (var at = from; at < to; at++) {
    if (text.codeUnitAt(at) != 0x40 || at < lastEnd) continue;
    final start = _localStart(text, lo, at);
    if (start == null) continue;
    final domainEnd = _domainEnd(text, at + 1, hi);
    if (domainEnd == null) continue;
    final mailto = _mailtoBefore(text, lo, start);
    var end = domainEnd;
    if (mailto != null && end < hi && text.codeUnitAt(end) == 0x3F) {
      final query = webEnd(text, mailto, _bodyEnd(text, end + 1, hi));
      if (query > end + 1) end = query;
    }
    out.add((start: mailto ?? start, at: at, end: end, mailto: mailto != null));
    lastEnd = end;
  }
  return out;
}

/// The URL of [email], a link of [text]: `mailto:`, or the written `mailto:`
/// as written, then the local part with '%' as `%25`, '@', and the domain
/// and query as written; where the email holds a Bidi_Control, its text, after
/// `mailto:` where no written one starts it.
String emailUrl(String text, Email email) {
  final (:start, :at, :end, :mailto) = email;
  for (var i = start; i < end; i++) {
    if (isBidiControl(text.codeUnitAt(i))) {
      final linked = text.substring(start, end);
      return mailto ? linked : 'mailto:$linked';
    }
  }
  final local = start + (mailto ? 7 : 0);
  final out = StringBuffer(mailto ? text.substring(start, local) : 'mailto:');
  for (var i = local; i < at; i++) {
    final c = text.codeUnitAt(i);
    if (c == 0x25) {
      out.write('%25');
    } else {
      out.writeCharCode(c);
    }
  }
  return (out..write(text.substring(at, end))).toString();
}

/// Whether the UTF-16 unit [c] is in EMAIL_ADDRESS's local class: an ASCII
/// letter or digit, '.', '_', '%', '+' or '-'.
bool _local(int c) =>
    isAsciiLetter(c) ||
    isAsciiDigit(c) ||
    c == 0x2E ||
    c == 0x5F ||
    c == 0x25 ||
    c == 0x2B ||
    c == 0x2D;

/// The start of the local part before the '@' at [at], no earlier than
/// [lo], or null where none ends there.
int? _localStart(String text, int lo, int at) {
  int? start;
  var count = 0;
  for (var i = at; i > lo; i--) {
    final c = text.codeUnitAt(i - 1);
    if (_local(c)) {
      if (++count > 256) break;
      start = i - 1;
    } else if (!isBidiControl(c)) {
      break;
    }
  }
  return start;
}

bool _alnum(int c) => isAsciiLetter(c) || isAsciiDigit(c);

/// The end of the domain at [p], or null where no R5 domain starts there.
int? _domainEnd(String text, int p, int hi) {
  var i = _pastBidi(text, p, hi);
  var labels = 0;
  var lastLabel = i;
  int? end;
  while (i < hi && _alnum(text.codeUnitAt(i))) {
    lastLabel = i;
    var last = i;
    var q = i + 1;
    while (q < hi) {
      final c = text.codeUnitAt(q);
      if (_alnum(c)) {
        last = q;
      } else if (!(c == 0x2D || c == 0x5F || isBidiControl(c))) {
        break;
      }
      q++;
    }
    labels++;
    end = last + 1;
    final dot = _pastBidi(text, end, hi);
    if (dot >= hi || text.codeUnitAt(dot) != 0x2E) break;
    i = _pastBidi(text, dot + 1, hi);
  }
  if (labels < 2 || !_tldAt(text, lastLabel, end!)) return null;
  return end;
}

int _pastBidi(String text, int i, int hi) {
  while (i < hi && isBidiControl(text.codeUnitAt(i))) {
    i++;
  }
  return i;
}

/// Whether the label from [start] to [end], without its Bidi_Controls, is a
/// TLD in any case.
bool _tldAt(String text, int start, int end) {
  final label = StringBuffer();
  for (var i = start; i < end; i++) {
    final c = text.codeUnitAt(i);
    if (!isBidiControl(c)) label.writeCharCode(c);
  }
  return isTldInAnyCase(label.toString());
}

/// Where a `mailto:` that joins the local part at [start] starts, or null.
int? _mailtoBefore(String text, int lo, int start) {
  var j = start;
  while (j > lo && isBidiControl(text.codeUnitAt(j - 1))) {
    j--;
  }
  final m = j - 7;
  if (m < lo || text.codeUnitAt(j - 1) != 0x3A) return null;
  for (var k = 0; k < 6; k++) {
    if (text.codeUnitAt(m + k) | 0x20 != 'mailto'.codeUnitAt(k)) return null;
  }
  if (m > lo) {
    final c = text.codeUnitAt(m - 1);
    if (_alnum(c) || c == 0x5F) return null;
  }
  return m;
}

/// The end of R1's body at [p]: before whitespace, a C0 or C1 control or DEL,
/// CJK punctuation, one of `" < > [ \ ] ^ ` { | }`, or a '%' that two hex
/// digits do not follow.
int _bodyEnd(String text, int p, int hi) {
  var i = p;
  while (i < hi) {
    final c = text.codeUnitAt(i);
    if (c == 0x25) {
      if (i + 2 < hi &&
          isHex(text.codeUnitAt(i + 1)) &&
          isHex(text.codeUnitAt(i + 2))) {
        i += 3;
        continue;
      }
      break;
    }
    if (c <= 0x20 ||
        (c >= 0x7F && c <= 0x9F) ||
        isPathStop(c) ||
        isIcuSpace(c) ||
        isCjkPunctuation(c)) {
      break;
    }
    i++;
  }
  return i;
}
