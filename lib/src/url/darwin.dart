import 'package:ux/src/url/any_scheme.dart';
import 'package:ux/src/url/chars.dart';
import 'package:ux/src/url/match.dart';
import 'package:ux/src/url/nsdd.dart';
import 'package:ux/src/url/nsdd_model.dart';
import 'package:ux/src/url/web_pass.dart';

/// A stage-2 candidate: a link and whether NSDataDetector's model gave it.
typedef Candidate = ({UrlMatch link, bool nsdd});

/// url_detect.mm's stage-2 candidates of [text]: NSDataDetector's, then the
/// second pass's.
List<Candidate> stage2(String text) => [
  for (final link in nsddCandidates(text, nsddResults(text)))
    (link: link, nsdd: true),
  for (final link in webPass(text)) (link: link, nsdd: false),
];

/// The links of [text] as darwin reads them from its stage-2 candidates.
List<UrlMatch> darwinReading(String text) {
  if (text.isEmpty || !hasSigil(text)) return const [];
  return finish(
    text,
    stage3(text, [for (final c in stage2(text)) c.link]).kept,
    anySchemeLinks(text),
  );
}

/// What stage 3 keeps of the candidates, and the fullwidth '(' of each cut it
/// sets.
typedef Deduped = ({List<UrlMatch> kept, List<int> cuts});

int _kindOrder(UrlMatchKind kind) => switch (kind) {
  UrlMatchKind.web => 0,
  UrlMatchKind.email => 1,
  UrlMatchKind.phone => 2,
};

/// url_detect.mm's stage 3 over [candidates] of [text]: sort by start, then
/// length descending, then phone, email, web; then walk that order, skipping
/// a web candidate, or one of any kind where [everyKind] holds, that
/// continues the path of the current cut, setting the cut at a web candidate
/// whose path runs on to a fullwidth '(', and dropping a candidate that
/// starts before the last kept end.
Deduped stage3(
  String text,
  List<UrlMatch> candidates, {
  bool everyKind = false,
}) {
  final order = [for (var i = 0; i < candidates.length; i++) i]
    ..sort((x, y) {
      final a = candidates[x];
      final b = candidates[y];
      if (a.start != b.start) return a.start.compareTo(b.start);
      final la = a.end - a.start;
      final lb = b.end - b.start;
      if (la != lb) return lb.compareTo(la);
      final ka = _kindOrder(a.kind);
      final kb = _kindOrder(b.kind);
      if (ka != kb) return kb.compareTo(ka);
      return x.compareTo(y);
    });
  final kept = <UrlMatch>[];
  final cuts = <int>[];
  var lastEnd = 0;
  var any = false;
  int? cut;
  for (final i in order) {
    final m = candidates[i];
    final web = m.kind == UrlMatchKind.web;
    if ((web || everyKind) &&
        cut != null &&
        continuesPath(text, cut, m.start, m.end)) {
      continue;
    }
    if (web) {
      final paren = pathParen(text, m.start, m.end);
      if (paren != null) {
        cut = paren;
        cuts.add(paren);
      }
    }
    if (any && m.start < lastEnd) continue;
    kept.add(m);
    lastEnd = m.end;
    any = true;
  }
  return (kept: kept, cuts: cuts);
}

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
  while (from < start && !_isPathDelimiter(text.codeUnitAt(from))) {
    from++;
  }
  return from < start && pathMark(text, paren, end) == end;
}

bool _isPathDelimiter(int c) =>
    c == 0x2F || c == 0x3F || c == 0x23 || c == 0x26 || c == 0x3D;

/// Stage 1: whether [text] holds a '.', ':', '@' or '+', or five ASCII
/// digits.
bool hasSigil(String text) {
  var digits = 0;
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (c == 0x2E || c == 0x3A || c == 0x40 || c == 0x2B) return true;
    if (isAsciiDigit(c) && ++digits >= 5) return true;
  }
  return false;
}

/// The links stage 4 keeps of stage 3's: the first 64.
const maxNativeLinks = 64;

/// Stages 4 to 7 over [native], stage 3's links of [text]: the cap, each
/// URL's bidi controls and sanitizing, the phone filter, then the merge with
/// [anyScheme], the any-scheme pass's links.
List<UrlMatch> finish(
  String text,
  List<UrlMatch> native,
  List<UrlMatch> anyScheme,
) {
  final links = [
    for (final m in native.take(maxNativeLinks))
      if (m.kind != UrlMatchKind.phone || _keepsPhone(text, m))
        UrlMatch(
          start: m.start,
          end: m.end,
          url: sanitizeUrl(_keepBidiControls(m, text)),
          kind: m.kind,
        ),
  ];
  if (!text.contains('://') || anyScheme.isEmpty) return links;
  return dedupe([...links, ...anyScheme]);
}

/// `_keepBidiControls`: the URL of [m], a link of [text], or, for an email
/// or phone whose text holds a bidi control its URL leaves out, its scheme
/// and that text, or the text alone where it starts with the scheme.
String _keepBidiControls(UrlMatch m, String text) {
  final scheme = switch (m.kind) {
    UrlMatchKind.web => null,
    UrlMatchKind.email => 'mailto:',
    UrlMatchKind.phone => 'tel:',
  };
  if (scheme == null || m.url.codeUnits.any(isBidiControl)) return m.url;
  final linked = text.substring(m.start, m.end);
  if (!linked.codeUnits.any(isBidiControl)) return m.url;
  return linked.toLowerCase().startsWith(scheme) ? linked : '$scheme$linked';
}

/// The phone filter: whether the phone [m] starts the text or follows a
/// space, tab, LF, CR, NBSP, U+3000, U+2028 or U+2029, and its first
/// character is an ASCII '(', '+' or '0'.
bool _keepsPhone(String text, UrlMatch m) {
  if (m.start > 0) {
    final c = text.codeUnitAt(m.start - 1);
    if (!(c == 0x20 ||
        c == 0x09 ||
        c == 0x0A ||
        c == 0x0D ||
        c == 0xA0 ||
        c == 0x3000 ||
        c == 0x2028 ||
        c == 0x2029)) {
      return false;
    }
  }
  if (m.start >= m.end || m.start >= text.length) return false;
  final first = text.codeUnitAt(m.start);
  return first == 0x28 || first == 0x2B || first == 0x30;
}

/// `_dedupeMatches`: sort by start, longer first, then kind index
/// descending, and drop a link that starts inside the last kept one.
List<UrlMatch> dedupe(List<UrlMatch> links) {
  links.sort((a, b) {
    if (a.start != b.start) return a.start.compareTo(b.start);
    final lenA = a.end - a.start;
    final lenB = b.end - b.start;
    if (lenA != lenB) return lenB.compareTo(lenA);
    return b.kind.index.compareTo(a.kind.index);
  });
  final out = <UrlMatch>[];
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
