import 'dart:typed_data';

import 'package:ux/src/url/any_scheme.dart';
import 'package:ux/src/url/chars.dart';
import 'package:ux/src/url/match.dart';
import 'package:ux/src/url/nsdd.dart';
import 'package:ux/src/url/nsdd_model.dart';
import 'package:ux/src/url/web_pass.dart';

/// A stage-2 candidate: a link and whether NSDataDetector's model gave it.
typedef Candidate = ({UrlMatch link, bool nsdd});

/// url_detect.mm's stage-2 candidates of [text], whose NSDataDetector results
/// are [raw]: NSDataDetector's, then the second pass's.
List<Candidate> stage2(String text, List<NsddResult> raw) => [
  for (final link in nsddCandidates(text, raw)) (link: link, nsdd: true),
  for (final link in webPass(text)) (link: link, nsdd: false),
];

/// What stage 3 keeps of the candidates, and the fullwidth '(' of each cut it
/// sets.
typedef Deduped = ({List<UrlMatch> kept, List<int> cuts});

int _kindOrder(UrlMatchKind kind) => switch (kind) {
  UrlMatchKind.web => 0,
  UrlMatchKind.email => 1,
  UrlMatchKind.phone => 2,
};

/// url_detect.mm's stage 3 over [candidates] of the text [index] looks up:
/// sort by start, then length descending, then phone, email, web; then walk
/// that order, skipping a web candidate, or one of any kind where
/// [everyKind] holds, that continues the path of the current cut, setting
/// the cut at a web candidate whose path runs on to a fullwidth '(', and
/// dropping a candidate that starts before the last kept end.
Deduped stage3(
  PathIndex index,
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
        index.continuesPath(cut, m.start, m.end)) {
      continue;
    }
    if (web) {
      final paren = index.pathParen(m.start, m.end);
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

/// The look-ups of stage 3's continuation cut in [text], each built once.
class PathIndex {
  /// The look-ups of [text].
  PathIndex(this.text);

  /// The text looked up.
  final String text;

  late final bool _paren = text.contains('\uFF08');

  late final Int32List _nextCjk = _forward(isCjkPunctuation);

  late final Int32List _lastCjks = () {
    final n = text.length;
    final out = Int32List(n + 1)..[0] = -1;
    for (var i = 1; i <= n; i++) {
      out[i] = isCjkPunctuation(text.codeUnitAt(i - 1)) ? i - 1 : out[i - 1];
    }
    return out;
  }();

  /// The last CJK punctuation before [i].
  int? _lastCjk(int i) {
    final at = _lastCjks[i];
    return at < 0 ? null : at;
  }

  late final Int32List _nextDelimiter = _forward(_isPathDelimiter);

  /// For each offset, the first code point at or after it that ends
  /// Patterns.WEB_URL's path where the path runs to the text's end, stepping
  /// over whole surrogate pairs; a pair's low surrogate is never one.
  late final Int32List _nextMark = () {
    final n = text.length;
    final mark = List.filled(n, false);
    for (var i = 0; i < n;) {
      final next = _markStep(i, n);
      mark[i] = next == null;
      i = next ?? _width(i, n);
    }
    final out = Int32List(n + 1)..[n] = n;
    for (var i = n - 1; i >= 0; i--) {
      out[i] = mark[i] ? i : out[i + 1];
    }
    return out;
  }();

  Int32List _forward(bool Function(int) test) {
    final n = text.length;
    final out = Int32List(n + 1)..[n] = n;
    for (var i = n - 1; i >= 0; i--) {
      out[i] = test(text.codeUnitAt(i)) ? i : out[i + 1];
    }
    return out;
  }

  /// Where ux_path_mark's scan bounded by [end] steps on from [i], or null
  /// where the character at [i] ends the path.
  int? _markStep(int i, int end) {
    final c = text.codeUnitAt(i);
    if (c == 0x25) {
      return i + 2 < end &&
              isHex(text.codeUnitAt(i + 1)) &&
              isHex(text.codeUnitAt(i + 2))
          ? i + 1
          : null;
    }
    if (c < 0x80) {
      return c <= 0x20 || c == 0x7F || '"<>[\\]^`{|}'.codeUnits.contains(c)
          ? null
          : i + 1;
    }
    if (c >= 0xD800 &&
        c <= 0xDBFF &&
        i + 1 < end &&
        _isLow(text.codeUnitAt(i + 1))) {
      final cp =
          0x10000 + ((c - 0xD800) << 10) + (text.codeUnitAt(i + 1) - 0xDC00);
      return isUcsChar(cp) ? i + 2 : null;
    }
    return isUcsChar(c) ? i + 1 : null;
  }

  int _width(int i, int n) =>
      i + 1 < n && _isHigh(text.codeUnitAt(i)) && _isLow(text.codeUnitAt(i + 1))
      ? i + 2
      : i + 1;

  static bool _isHigh(int c) => c >= 0xD800 && c <= 0xDBFF;

  static bool _isLow(int c) => c >= 0xDC00 && c <= 0xDFFF;

  /// [pathMark] of the text from [i] to [end].
  int pathMarkTo(int i, int end) {
    if (i >= end) return i;
    if (i > 0 &&
        _isLow(text.codeUnitAt(i)) &&
        _isHigh(text.codeUnitAt(i - 1))) {
      return i;
    }
    final mark = _nextMark[i];
    if (mark < end - 2) return mark;
    var q = end - 2;
    if (q - 1 >= i &&
        _isHigh(text.codeUnitAt(q - 1)) &&
        _isLow(text.codeUnitAt(q))) {
      q++;
    }
    if (q < i) q = i;
    while (q < end) {
      final next = _markStep(q, end);
      if (next == null) return q;
      q = next;
    }
    return q;
  }

  /// ux_path_paren: the fullwidth '(' that ends the stretch between CJK
  /// punctuation the web match [start, end) ends in, where its path runs on
  /// to it.
  int? pathParen(int start, int end) {
    if (!_paren || pathStart(text, start, end) == end) return null;
    final paren = _nextCjk[end];
    if (paren == text.length ||
        text.codeUnitAt(paren) != 0xFF08 ||
        pathMarkTo(end, paren) < paren) {
      return null;
    }
    return paren;
  }

  /// ux_continues_path: whether the web match [start, end) continues the
  /// path that runs on to the fullwidth '(' at [paren].
  bool continuesPath(int paren, int start, int end) {
    if (start <= paren) return false;
    final last = _lastCjk(start)!;
    if (text.codeUnitAt(last) != 0xFF09) return false;
    return _nextDelimiter[last + 1] < start && pathMarkTo(paren, end) == end;
  }

  /// Whether the cut nearest before [link], of the sorted [cuts], covers it:
  /// only that cut can.
  bool covers(List<int> cuts, UrlMatch link) {
    var lo = 0;
    var hi = cuts.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (cuts[mid] < link.start) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo > 0 && continuesPath(cuts[lo - 1], link.start, link.end);
  }
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
/// [anyScheme], the any-scheme pass's links. [cap] is what the cap leaves of
/// [native].
List<UrlMatch> finish(
  String text,
  List<UrlMatch> native,
  List<UrlMatch> anyScheme, {
  int cap = maxNativeLinks,
}) {
  final links = [
    for (final m in native.take(cap < 0 ? 0 : cap))
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
