import 'package:ux/src/url/any_scheme.dart';
import 'package:ux/src/url/chars.dart';
import 'package:ux/src/url/detect.dart';
import 'package:ux/src/url/match.dart';
import 'package:ux/src/url/reading.dart';

/// A phone the platform's detector reads: its UTF-16 span and its phone
/// string, NSDataDetector's `phoneNumber` on iOS or the match's text on
/// Android.
typedef PlatformPhone = ({int start, int end, String phone});

/// The phones the platform's detector reads in the first [length] units of
/// [text].
typedef PhoneReader = List<PlatformPhone> Function(String text, int length);

/// The phones a text keeps.
const maxPhones = 64;

/// [links], the links [detectLinks] reads in [text], with the phones [read]
/// reads in the units [boundOf] gives, sorted by start. [read] runs only where
/// [mayHoldPhone] holds.
///
/// A phone joins where it starts at the text's start or after a space, tab,
/// LF, CR, NBSP, U+3000, U+2028 or U+2029 with an ASCII '(', '+' or '0', its
/// text holds no invisible space, it overlaps no link of [links], its number
/// holds seven digits or more and it does not end where a text of more than
/// [inputBound] units is cut. The first [maxPhones] that join are kept.
///
/// A phone's number is the '+' and ASCII digits of its phone string before
/// the string's first ';' or ASCII letter, and its URL is `tel:` and that
/// number, or, where its text holds a Bidi_Control, `tel:` and the text.
List<UrlMatch> withPhones(String text, List<UrlMatch> links, PhoneReader read) {
  if (!mayHoldPhone(text)) return links;
  final n = boundOf(text);
  final phones = read(text, n)..sort((a, b) => a.start - b.start);
  final out = <UrlMatch>[];
  var kept = 0;
  var l = 0;
  for (final p in phones) {
    if (kept == maxPhones) break;
    while (l < links.length && links[l].end <= p.start) {
      out.add(links[l++]);
    }
    if (l < links.length && links[l].start < p.end) continue;
    final url = _url(text, n, p);
    if (url == null) continue;
    out.add(
      UrlMatch(start: p.start, end: p.end, url: url, kind: UrlMatchKind.phone),
    );
    kept++;
  }
  return out..addAll(links.skip(l));
}

/// Whether the units [boundOf] gives of [text] may hold a phone: an ASCII
/// '(', '+' or '0' at its start or after a space, tab, LF, CR, NBSP, U+3000,
/// U+2028 or U+2029, and seven ASCII or fullwidth digits.
bool mayHoldPhone(String text) {
  final n = boundOf(text);
  var lead = false;
  var digits = 0;
  for (var i = 0; i < n; i++) {
    final c = text.codeUnitAt(i);
    if (isAsciiDigit(c) || (c >= 0xFF10 && c <= 0xFF19)) digits++;
    if (!lead && _isLead(c) && (i == 0 || _isSpace(text.codeUnitAt(i - 1)))) {
      lead = true;
    }
    if (lead && digits >= 7) return true;
  }
  return false;
}

/// The URL of the phone [p] of [text], whose read units end at [n], or null
/// where it does not join.
String? _url(String text, int n, PlatformPhone p) {
  final (:start, :end, :phone) = p;
  if (!_isLead(text.codeUnitAt(start)) ||
      (start > 0 && !_isSpace(text.codeUnitAt(start - 1))) ||
      (end == n && n < text.length)) {
    return null;
  }
  var bidi = false;
  for (var i = start; i < end; i++) {
    final c = text.codeUnitAt(i);
    if (isInvisibleSpace(c)) return null;
    if (isBidiControl(c)) bidi = true;
  }
  final number = StringBuffer('tel:');
  var digits = 0;
  for (final c in phone.codeUnits) {
    if (c == 0x3B || isAsciiLetter(c)) break;
    if (isAsciiDigit(c)) digits++;
    if (c == 0x2B || isAsciiDigit(c)) number.writeCharCode(c);
  }
  if (digits < 7) return null;
  return bidi
      ? sanitizeUrl('tel:${text.substring(start, end)}')
      : number.toString();
}

bool _isLead(int c) => c == 0x28 || c == 0x2B || c == 0x30;

bool _isSpace(int c) =>
    c == 0x20 ||
    c == 0x09 ||
    c == 0x0A ||
    c == 0x0D ||
    c == 0xA0 ||
    c == 0x3000 ||
    c == 0x2028 ||
    c == 0x2029;
