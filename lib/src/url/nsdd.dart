import 'package:ux/src/url/chars.dart';
import 'package:ux/src/url/match.dart';
import 'package:ux/src/url/nsdd_model.dart';
import 'package:ux/src/url/web_pass.dart';

/// url_detect.mm's candidates from NSDataDetector's [results] of [text]: a
/// phone that is no dotted IPv4 address and holds seven ASCII digits after
/// NFKD folding, before its first ASCII letter, as `tel:` and those digits;
/// a link whose scheme is `mailto` as an email with its URL; and any other
/// link as a web link ended by [webEnd] where no '.' glues a word to it,
/// with no written scheme ended before a port that a letter follows and
/// kept where it has a TLD, its URL its text after any scheme it does not
/// write.
List<UrlMatch> nsddCandidates(String text, List<NsddResult> results) {
  final out = <UrlMatch>[];
  for (final r in results) {
    if (r.start >= r.end) continue;
    var end = r.end;
    String url;
    UrlMatchKind kind;
    if (r.phone) {
      if (_isIpv4(text, r.start, r.end)) continue;
      final digits = StringBuffer();
      var seenLetter = false;
      var count = 0;
      for (final c in nfkdDigits(r.value).codeUnits) {
        if (isAsciiDigit(c) || c == 0x2B) {
          if (seenLetter) break;
          digits.writeCharCode(c);
          if (c != 0x2B) count++;
        } else if (isAsciiLetter(c)) {
          seenLetter = true;
        }
      }
      if (count < 7) continue;
      url = 'tel:$digits';
      kind = UrlMatchKind.phone;
    } else {
      final colon = r.value.indexOf(':');
      final scheme = colon < 0 ? '' : r.value.substring(0, colon).toLowerCase();
      kind = scheme == 'mailto' ? UrlMatchKind.email : UrlMatchKind.web;
      url = r.value;
      if (kind == UrlMatchKind.web) {
        end = webEnd(text, r.start, end);
        if (gluesWord(text, r.start, end)) continue;
        var kept = text.substring(r.start, end);
        final prefix = '$scheme:';
        final written = kept.toLowerCase().startsWith(prefix);
        if (!written) {
          end = _portEnd(text, r.start, end);
          if (!hasTld(text, r.start, end)) continue;
          kept = kept.substring(0, end - r.start);
        }
        url = written ? kept : '$prefix//$kept';
      }
    }
    if (url.isEmpty) continue;
    out.add(UrlMatch(start: r.start, end: end, url: url, kind: kind));
  }
  return out;
}

/// ux_is_ipv4: whether [start, end) of [text] is ASCII digits and '.' alone
/// that no '0' starts and that the second pass's pattern matches whole.
bool _isIpv4(String text, int start, int end) {
  if (text.codeUnitAt(start) == 0x30) return false;
  for (var i = start; i < end; i++) {
    final c = text.codeUnitAt(i);
    if (c != 0x2E && !isAsciiDigit(c)) return false;
  }
  return matchesWhole(text.substring(start, end));
}

/// ux_port_end: the end of the web match [start, end), which has no scheme,
/// before a port that a letter follows, where no word boundary ends
/// Patterns.WEB_URL's port; a port of ASCII digits that an unspaced letter
/// follows stays.
int _portEnd(String text, int start, int end) {
  final host = hostEnd(text, start, end);
  if (host == end ||
      text.codeUnitAt(host) != 0x3A ||
      end == text.length ||
      !isMacLetter(cpAt(text, end))) {
    return end;
  }
  var ascii = true;
  for (var i = host + 1; i < end; i++) {
    final c = text.codeUnitAt(i);
    if (!isDigit(c)) return end;
    ascii = ascii && isAsciiDigit(c);
  }
  return ascii && isUnspacedUnit(text.codeUnitAt(end)) ? end : host;
}

/// [s] with each fullwidth ASCII form as its ASCII character, as NFKD folds
/// it.
String nfkdDigits(String s) => String.fromCharCodes(
  s.codeUnits.map((c) => c >= 0xFF01 && c <= 0xFF5E ? c - 0xFF01 + 0x21 : c),
);
