import 'dart:typed_data';

import 'package:ux/src/url/any_scheme.dart';
import 'package:ux/src/url/chars.dart';
import 'package:ux/src/url/email.dart';
import 'package:ux/src/url/match.dart';
import 'package:ux/src/url/nsdd_model.dart';
import 'package:ux/src/url/web_pass.dart';

/// Where a candidate comes from, which decides its kind and URL.
enum Source {
  /// NSDataDetector's model: a scheme link or an opaque URI.
  nsdd,

  /// The second pass's link that writes a scheme.
  written,

  /// A host with no scheme: `http://` and its text.
  bare,

  /// An email.
  email,

  /// The any-scheme pass's link.
  anyScheme,
}

/// A link of a token's reading. An email's [at] is its '@', and [mailto]
/// holds where a written `mailto:` starts it.
final class Link {
  /// A link from [source] over [start] to [end].
  const Link(this.start, this.end, this.source, {this.at, this.mailto = false});

  /// Inclusive UTF-16 offset.
  final int start;

  /// Exclusive UTF-16 offset.
  final int end;

  /// Where it comes from.
  final Source source;

  /// An email's '@'.
  final int? at;

  /// Whether a written `mailto:` starts the email.
  final bool mailto;

  /// Its kind.
  UrlMatchKind get kind =>
      source == Source.email ? UrlMatchKind.email : UrlMatchKind.web;

  /// This link ended at [end].
  Link endedAt(int end) => Link(start, end, source, at: at, mailto: mailto);

  /// This link as R5's email.
  Email get email => (start: start, at: at!, end: end, mailto: mailto);
}

/// A token's reading: its native links after stage 3 and its any-scheme
/// links that no continuation cut covers.
typedef TokenReading = ({List<Link> native, List<Link> any});

/// The links the token from [start] to [end] of [text], whose readable
/// units end at [n], reads in its window, from the unit before it to three
/// after it, with [before] native links kept before it.
TokenReading readToken(String text, int n, int start, int end, int before) {
  final lo = start == 0 ? 0 : start - 1;
  final hi = end + 3 > n ? n : end + 3;
  final reading = _Reading(text, lo, hi, start, end, 0, before);
  final state = reading.edited();
  final st3 = reading.stage3(state.cands);
  return (
    native: st3.kept,
    any: st3.cuts.isEmpty
        ? state.any
        : [
            for (final l in state.any)
              if (!reading.index.covers(st3.cuts, l)) l,
          ],
  );
}

/// The links stage 4 keeps of stage 3's: the first 64.
const maxNativeLinks = 64;

/// Text a cut other than an invisible space's removes from a link, read as
/// a text of its own.
typedef _Region = ({int start, int from, int to});

/// Text an invisible space cuts off [whole], the link as that cut finds it,
/// from [from], where [any] holds an any-scheme link's; [link] is what the
/// cuts leave of it.
typedef _CutOff = ({Link whole, Link? link, int from, bool any});

typedef _State = ({List<Link> cands, List<Link> any});

/// One text the edits read: a token's window from [lo] to [hi], whose token
/// is [start] to [end], at level 0, a remainder of it at level 1 and a
/// remainder of that at level 2.
class _Reading {
  _Reading(
    this.text,
    this.lo,
    this.hi,
    this.start,
    this.end,
    this.level,
    this.before,
  );

  final String text;
  final int lo;
  final int hi;
  final int start;
  final int end;
  final int level;

  /// The native links kept before this text, which its cap counts.
  final int before;

  late final PathIndex index = PathIndex(text, lo, hi);

  /// The regions the cuts remove, and the text invisible spaces cut off.
  List<_Region>? _regions;
  List<_CutOff>? _cutOffs;

  /// The candidates and any-scheme links of the text after the ledger's
  /// edits and cuts, its remainders read.
  _State edited() {
    final cands = <Link>[];
    List<int>? webcals;
    for (final (s, e) in nsddLinks(text, lo, hi, start, end)) {
      final link = Link(s, e, Source.nsdd);
      if (_isWebcalSlash(s, e)) (webcals ??= []).add(s);
      if (_dropped(link)) continue;
      if (cut(link, any: false) case final kept?) cands.add(kept);
    }
    for (final idn in const [false, true]) {
      for (final (:start, :end, :written) in webPass(
        text,
        lo,
        hi,
        this.start,
        this.end,
        idn: idn,
      )) {
        final link = Link(start, end, written ? Source.written : Source.bare);
        if (written && _dropped(link)) continue;
        if (cut(link, any: false) case final kept?) cands.add(kept);
      }
    }
    for (final e in emailsOf(text, lo, hi, start, end)) {
      final link = Link(
        e.start,
        e.end,
        Source.email,
        at: e.at,
        mailto: e.mailto,
      );
      if (!e.mailto || e.end == _queryAt(link)) {
        cands.add(link);
      } else if (cut(link, any: false) case final kept?) {
        cands.add(kept);
      }
    }
    final any = <Link>[];
    for (final (s, e) in anySchemeLinks(text, lo, hi, start, end)) {
      final link = Link(s, e, Source.anyScheme);
      if (webcals != null && _webcalWithoutHost(webcals, link)) continue;
      if (cut(link, any: true) case final kept?) any.add(kept);
    }
    if (_regions == null && _cutOffs == null) return (cands: cands, any: any);
    return remainders(cands, any, _regions ?? const [], _cutOffs ?? const []);
  }

  /// [cands] and [any] with each remainder read as a text of its own (p2),
  /// and the text an invisible space cuts off each link the reading keeps
  /// whole starting no link.
  _State remainders(
    List<Link> cands,
    List<Link> any,
    List<_Region> regions,
    List<_CutOff> cutOffs,
  ) {
    final read = <_Region>[];
    if (level < 2) {
      final order =
          [
            for (final region in regions)
              if (region.from > region.start) region,
          ]..sort((a, b) {
            final byStart = a.from.compareTo(b.from);
            return byStart != 0
                ? byStart
                : (b.to - b.from).compareTo(a.to - a.from);
          });
      for (final region in order) {
        if (read.isEmpty || region.from >= read.last.to) read.add(region);
      }
    }
    bool replaced(int i) {
      final k = _lastAtOrBefore(read.length, (k) => read[k].from, i);
      return k != null && i < read[k].to;
    }

    if (read.isNotEmpty) {
      final subCands = <Link>[];
      final subAny = <Link>[];
      for (final region in read) {
        final sub = _Reading(
          text,
          region.from,
          region.to,
          region.from,
          region.to,
          level + 1,
          0,
        ).edited();
        subCands.addAll(sub.cands);
        subAny.addAll(sub.any);
      }
      cands = [
        for (final l in cands)
          if (!replaced(l.start)) l,
        ...subCands,
      ];
      any = [
        for (final l in any)
          if (!replaced(l.start)) l,
        ...subAny,
      ];
    }
    final live = [
      for (final o in cutOffs)
        if (!replaced(o.whole.start)) o,
    ];
    if (live.isEmpty) return (cands: cands, any: any);
    final cutLinks = {for (final o in live) ?o.link};
    List<Link> restored(List<Link> links, bool isAny) => [
      for (final l in links)
        if (!cutLinks.contains(l)) l,
      for (final o in live)
        if (o.any == isAny) o.whole,
    ];
    final spans = _stages(restored(cands, false), restored(any, true));
    final cutOff = [
      for (final o in live)
        if (spans.contains((o.whole.start, o.whole.end)))
          (from: o.from, to: o.whole.end),
    ]..sort((a, b) => a.from.compareTo(b.from));
    final reach = <int>[];
    for (final c in cutOff) {
      reach.add(reach.isEmpty || c.to > reach.last ? c.to : reach.last);
    }
    bool inside(int i) {
      final k = _lastAtOrBefore(cutOff.length, (k) => cutOff[k].from, i);
      return k != null && i < reach[k];
    }

    return (
      cands: [
        for (final l in cands)
          if (!inside(l.start)) l,
      ],
      any: [
        for (final l in any)
          if (!inside(l.start)) l,
      ],
    );
  }

  /// The spans of darwin's stages 3 to 7 over the candidates [cands] and
  /// the any-scheme links [any], the continuation cut skipping a candidate
  /// of every kind and an any-scheme link.
  Set<(int, int)> _stages(List<Link> cands, List<Link> any) {
    final st3 = stage3(cands);
    final cap = maxNativeLinks - before;
    final links = [
      ...st3.kept.take(cap < 0 ? 0 : cap),
      for (final l in any)
        if (!index.covers(st3.cuts, l)) l,
    ];
    return {for (final l in dedupe(links)) (l.start, l.end)};
  }

  /// url_detect.mm's stage 3 over [candidates]: sort by start, then length
  /// descending, then email before web; then walk that order, skipping a
  /// candidate that continues the path of the current cut, setting the cut
  /// at a web candidate whose path runs on to a fullwidth '(', and dropping
  /// a candidate that starts before the last kept end. The cuts come
  /// sorted.
  ({List<Link> kept, List<int> cuts}) stage3(List<Link> candidates) {
    if (candidates.isEmpty) return (kept: const [], cuts: const []);
    final order = List.of(candidates);
    if (order.length > 1) _sortLinks(order);
    final kept = <Link>[];
    List<int>? cuts;
    var lastEnd = 0;
    int? cut;
    for (final m in order) {
      if (cut != null && index.continuesPath(cut, m.start, m.end)) continue;
      if (m.source != Source.email) {
        final paren = index.pathParen(m.start, m.end);
        if (paren != null) {
          cut = paren;
          (cuts ??= []).add(paren);
        }
      }
      if (kept.isNotEmpty && m.start < lastEnd) continue;
      kept.add(m);
      lastEnd = m.end;
    }
    return (kept: kept, cuts: cuts == null ? const [] : (cuts..sort()));
  }

  /// Whether the link from [s] to [e] is NSDataDetector's `webcal:/` alone.
  bool _isWebcalSlash(int s, int e) =>
      e - s == 8 &&
      text.codeUnitAt(e - 1) == 0x2F &&
      text.codeUnitAt(e - 2) == 0x3A &&
      _lowerIs(s, 'webcal');

  bool _lowerIs(int i, String word) {
    for (var k = 0; k < word.length; k++) {
      if (text.codeUnitAt(i + k) | 0x20 != word.codeUnitAt(k)) return false;
    }
    return true;
  }

  /// Whether the written web link [link] gives no link: NSDataDetector's
  /// `webcal:/` alone, a scheme and at most two '/' that an invisible space
  /// follows, or a scheme and one '/' of a `scheme://` whose authority starts
  /// outside the host grammar.
  bool _dropped(Link link) {
    final colon = _schemeColon(link.start, link.end);
    if (colon == null || link.end - colon > 2) return false;
    for (var i = colon; i < link.end; i++) {
      if (text.codeUnitAt(i) != 0x2F) return false;
    }
    var q = colon;
    for (var k = 0; k < 2 && q < hi && text.codeUnitAt(q) == 0x2F; k++) {
      q++;
    }
    if (q < hi && isInvisibleSpace(cpAtIn(text, q, hi))) return true;
    if (link.source == Source.nsdd && _isWebcalSlash(link.start, link.end)) {
      return true;
    }
    final e = link.end;
    if (e != colon + 1 || e + 1 >= hi || text.codeUnitAt(e) != 0x2F) {
      return false;
    }
    final cp = cpAtIn(text, e + 1, hi);
    return !(cp == 0x2F || cp == 0x3F || cp == 0x23 || cp == 0x5B) &&
        !_hostChar(e + 1);
  }

  /// Whether the any-scheme link [l] is the one at a `webcal://` that
  /// NSDataDetector reads as `webcal:/` alone at one of [webcals], whose host
  /// holds a decimal digit outside ASCII and the fullwidth forms.
  bool _webcalWithoutHost(List<int> webcals, Link l) {
    if (!webcals.contains(l.start) ||
        l.end - l.start < 9 ||
        !_lowerIs(l.start, 'webcal') ||
        !text.startsWith('://', l.start + 6)) {
      return false;
    }
    for (var i = l.start + 9; i < l.end;) {
      final cp = cpAtIn(text, i, hi);
      if (cp == 0x2F || cp == 0x3F || cp == 0x23) return false;
      if (cp >= 0x80 && isDigit(cp) && !(cp >= 0xFF10 && cp <= 0xFF19)) {
        return true;
      }
      i += width(cp);
    }
    return false;
  }

  /// The end of the domain of the email [link], where its query starts.
  int _queryAt(Link link) {
    var i = link.at! + 1;
    while (i < link.end && text.codeUnitAt(i) != 0x3F) {
      i++;
    }
    return i;
  }

  /// [link] after the cuts, in their order until none changes it, each
  /// adding its region to [_regions], or an invisible space's to
  /// [_cutOffs]; null where a cut leaves no link. [any] marks an any-scheme
  /// link, which the any-scheme trim ends.
  Link? cut(Link link, {required bool any}) {
    Link? whole;
    var from = 0;
    Link? l = link;
    while (l != null) {
      final found = _cutAt(l);
      if (found == null) break;
      final (edit, at) = found;
      var end = any
          ? trimAnyScheme(text, l.start, at)
          : webEnd(text, l.start, at);
      if (l.source == Source.email && end == _queryAt(l) + 1) end--;
      if (edit == _Cut.invisibleSpace) {
        whole = l;
        from = end;
      } else {
        (_regions ??= []).add((start: l.start, from: end, to: l.end));
      }
      l = end <= l.start || _schemeAlone(l.start, end) ? null : l.endedAt(end);
    }
    if (whole != null) {
      (_cutOffs ??= []).add((whole: whole, link: l, from: from, any: any));
    }
    return l;
  }

  /// The first cut that ends [l] before its end, and where.
  (_Cut, int)? _cutAt(Link l) {
    final h = l.source == Source.bare || l.source == Source.email
        ? null
        : _hostStart(l);
    final hostCuts = h != null && h < l.end && text.codeUnitAt(h) != 0x5B;
    return _firstCut(l, hostCuts ? h : null);
  }

  /// The first cut that ends [l], whose host starts at [h] where the host
  /// cuts read it, before its end, and where.
  (_Cut, int)? _firstCut(Link l, int? h) {
    int? marks;
    int? unspaced;
    int? grammar;
    if (h != null) {
      var q = h;
      while (q < l.end) {
        final c = text.codeUnitAt(q);
        if (c < 0x80) {
          if (_isAuthorityMark(c)) break;
          if (grammar == null && !_hostChar(q)) grammar = q;
          q++;
          continue;
        }
        final cp = cpAtIn(text, q, hi);
        if (unspaced == null &&
            q > h &&
            isUnspaced(cp) &&
            !isUnspaced(cpBeforeIn(text, q, lo)) &&
            text.codeUnitAt(q - 1) != 0x2E) {
          unspaced = q;
        }
        if (grammar == null && !_hostChar(q)) grammar = q;
        q += width(cp);
      }
      if (q < l.end) {
        final c = text.codeUnitAt(q);
        if (c == 0x3F || c == 0x3A) {
          var r = q;
          while (r > h && _isTrimMark(text.codeUnitAt(r - 1))) {
            r--;
          }
          if (r < q) marks = r;
        }
      }
    }
    if (marks != null) return (_Cut.hostMarks, marks);
    var tail = l.end;
    while (tail > l.start && _isB3Tail(text.codeUnitAt(tail - 1))) {
      tail--;
    }
    int? invisible;
    int? paren;
    var open = 0;
    var nonAscii = false;
    for (var i = l.start; i < l.end; i++) {
      final c = text.codeUnitAt(i);
      if (c == 0x29) {
        if (paren == null && i + 1 >= tail && open <= 0) paren = i;
        open--;
      } else if (c == 0x28) {
        open++;
      } else if (c >= 0x80) {
        nonAscii = true;
        if (invisible == null && c >= 0x1680 && _invisibleAt(i)) {
          invisible = i;
        }
      }
    }
    if (invisible != null) return (_Cut.invisibleSpace, invisible);
    if (paren != null) return (_Cut.unopenedParen, paren);
    if (unspaced != null) return (_Cut.unspacedInHost, unspaced);
    if (nonAscii) {
      if (_trailingSymbolsCut(l) case final at?) {
        return (_Cut.trailingSymbols, at);
      }
      if (_closingQuotesCut(l) case final at?) return (_Cut.closingQuotes, at);
    }
    if (grammar != null) return (_Cut.hostGrammar, grammar);
    return null;
  }

  /// Whether the unit at [i] is an invisible space a link ends before: one
  /// [isInvisibleSpace] holds other than a ZWNJ or ZWJ between letters,
  /// marks, digits or symbols.
  bool _invisibleAt(int i) {
    final c = text.codeUnitAt(i);
    if (!isInvisibleSpace(c)) return false;
    return !((c == 0x200C || c == 0x200D) &&
        i > lo &&
        i + 1 < hi &&
        isJoinable(cpBeforeIn(text, i, lo)) &&
        isJoinable(cpAtIn(text, i + 1, hi)));
  }

  /// Where a non-word character follows [l], before the first character of
  /// its trailing non-word run that is neither ASCII nor Cf.
  int? _trailingSymbolsCut(Link l) {
    if (l.end >= hi || isWord(cpAtIn(text, l.end, hi))) return null;
    int? at;
    for (var i = l.end; i > l.start;) {
      final cp = cpBeforeIn(text, i, lo);
      if (isWord(cp)) break;
      i -= width(cp);
      if (cp >= 0x80 && !isFormat(cp)) at = i;
    }
    return at;
  }

  /// Before [l]'s trailing run of ” ’ ….
  int? _closingQuotesCut(Link l) {
    var e = l.end;
    while (e > l.start && _isClosingQuote(text.codeUnitAt(e - 1))) {
      e--;
    }
    return e < l.end ? e : null;
  }

  /// Whether the character at [i] is one a scheme link's host takes: a
  /// letter, mark, digit, Cf, '-', '_', '.' or a '%XX'.
  bool _hostChar(int i) {
    final c = text.codeUnitAt(i);
    if (c < 0x80) {
      if (c == 0x25) {
        return i + 2 < hi &&
            isHex(text.codeUnitAt(i + 1)) &&
            isHex(text.codeUnitAt(i + 2));
      }
      return isAsciiLetter(c) ||
          isAsciiDigit(c) ||
          c == 0x2D ||
          c == 0x5F ||
          c == 0x2E;
    }
    final cp = cpAtIn(text, i, hi);
    return isLetterMarkDigit(cp) || isFormat(cp);
  }

  /// Where the host of [l], a link written with a scheme and `://`, starts:
  /// after the `://` and any userinfo; null for a link without one.
  int? _hostStart(Link l) {
    if (!isAsciiLetter(text.codeUnitAt(l.start))) return null;
    var i = l.start + 1;
    while (i < l.end && _schemeRest(text.codeUnitAt(i))) {
      i++;
    }
    if (i + 3 > l.end || !text.startsWith('://', i)) return null;
    final authority = i + 3;
    int? at;
    for (var j = authority; j < l.end; j++) {
      final c = text.codeUnitAt(j);
      if (c == 0x2F || c == 0x3F || c == 0x23) break;
      if (c == 0x40) at = j;
    }
    return at == null ? authority : at + 1;
  }

  /// The end of the scheme and its ':' that start the text from [s] to [e].
  int? _schemeColon(int s, int e) {
    if (s >= e || !isAsciiLetter(text.codeUnitAt(s))) return null;
    var i = s + 1;
    while (i < e && _schemeRest(text.codeUnitAt(i))) {
      i++;
    }
    return i < e && text.codeUnitAt(i) == 0x3A ? i + 1 : null;
  }

  /// Whether the text from [s] to [e] is a scheme, its ':' and at most two
  /// '/'.
  bool _schemeAlone(int s, int e) {
    final colon = _schemeColon(s, e);
    if (colon == null || e - colon > 2) return false;
    for (var i = colon; i < e; i++) {
      if (text.codeUnitAt(i) != 0x2F) return false;
    }
    return true;
  }
}

/// The cuts, in the order they apply.
enum _Cut {
  hostMarks,
  invisibleSpace,
  unopenedParen,
  unspacedInHost,
  trailingSymbols,
  closingQuotes,
  hostGrammar,
}

/// [links] sorted by start, then length descending, then email before web,
/// keeping their order otherwise.
void _sortLinks(List<Link> links) {
  for (var i = 1; i < links.length; i++) {
    final x = links[i];
    var j = i - 1;
    while (j >= 0 && _before(x, links[j])) {
      links[j + 1] = links[j];
      j--;
    }
    links[j + 1] = x;
  }
}

/// Whether [a] sorts before [b] in stage 3's order.
bool _before(Link a, Link b) {
  if (a.start != b.start) return a.start < b.start;
  final la = a.end - a.start;
  final lb = b.end - b.start;
  if (la != lb) return la > lb;
  return a.source == Source.email && b.source != Source.email;
}

/// `_dedupeMatches`: [links] sorted by start, longer first, then email
/// before web, keeping their order otherwise, without a link that starts
/// inside the last kept one.
List<Link> dedupe(List<Link> links) {
  _sortLinks(links);
  final out = <Link>[];
  var lastEnd = 0;
  for (final m in links) {
    if (out.isNotEmpty && m.start < lastEnd) continue;
    out.add(m);
    lastEnd = m.end;
  }
  return out;
}

/// The look-ups of stage 3's continuation cut in the text [text] holds from
/// [lo] to [hi], each built once.
class PathIndex {
  /// The look-ups of [text] from [lo] to [hi].
  PathIndex(this.text, this.lo, this.hi);

  /// The text looked up.
  final String text;

  /// Where the text looked up starts.
  final int lo;

  /// Where the text looked up ends.
  final int hi;

  late final bool _paren = () {
    for (var i = lo; i < hi; i++) {
      if (text.codeUnitAt(i) == 0xFF08) return true;
    }
    return false;
  }();

  late final Int32List _nextCjk = _forward(isCjkPunctuation);

  late final Int32List _lastCjks = () {
    final out = Int32List(hi - lo + 1)..[0] = -1;
    for (var i = lo + 1; i <= hi; i++) {
      out[i - lo] = isCjkPunctuation(text.codeUnitAt(i - 1))
          ? i - 1
          : out[i - lo - 1];
    }
    return out;
  }();

  late final Int32List _nextDelimiter = _forward(_isPathDelimiter);

  /// For each offset, the first code point at or after it that ends
  /// Patterns.WEB_URL's path where the path runs to the text's end, stepping
  /// over whole surrogate pairs; a pair's low surrogate is never one.
  late final Int32List _nextMark = () {
    final mark = List.filled(hi - lo, false);
    for (var i = lo; i < hi;) {
      final next = _markStep(i, hi);
      mark[i - lo] = next == null;
      i = next ?? _width(i);
    }
    final out = Int32List(hi - lo + 1)..[hi - lo] = hi;
    for (var i = hi - 1; i >= lo; i--) {
      out[i - lo] = mark[i - lo] ? i : out[i - lo + 1];
    }
    return out;
  }();

  Int32List _forward(bool Function(int) test) {
    final out = Int32List(hi - lo + 1)..[hi - lo] = hi;
    for (var i = hi - 1; i >= lo; i--) {
      out[i - lo] = test(text.codeUnitAt(i)) ? i : out[i - lo + 1];
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
    if (c < 0x80) return c <= 0x20 || c == 0x7F || isPathStop(c) ? null : i + 1;
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

  int _width(int i) =>
      i + 1 < hi &&
          _isHigh(text.codeUnitAt(i)) &&
          _isLow(text.codeUnitAt(i + 1))
      ? i + 2
      : i + 1;

  static bool _isHigh(int c) => c >= 0xD800 && c <= 0xDBFF;

  static bool _isLow(int c) => c >= 0xDC00 && c <= 0xDFFF;

  /// [pathMark] of the text from [i] to [end].
  int pathMarkTo(int i, int end) {
    if (i >= end) return i;
    if (i > lo &&
        _isLow(text.codeUnitAt(i)) &&
        _isHigh(text.codeUnitAt(i - 1))) {
      return i;
    }
    final mark = _nextMark[i - lo];
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
    final paren = _nextCjk[end - lo];
    if (paren == hi ||
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
    final last = _lastCjks[start - lo];
    if (text.codeUnitAt(last) != 0xFF09) return false;
    return _nextDelimiter[last + 1 - lo] < start &&
        pathMarkTo(paren, end) == end;
  }

  /// Whether the cut nearest before [link], of the sorted [cuts], covers it:
  /// only that cut can.
  bool covers(List<int> cuts, Link link) {
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

/// The last of [count] sorted keys, [keyAt] each, at or before [i].
int? _lastAtOrBefore(int count, int Function(int) keyAt, int i) {
  var lo = 0;
  var hi = count;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (keyAt(mid) <= i) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo == 0 ? null : lo - 1;
}

/// Whether [cp] is an invisible space a link ends before: one a darwin link
/// holds in its text and leaves out of its URL, or U+1680.
bool isInvisibleSpace(int cp) =>
    cp == 0x1680 ||
    (cp >= 0x200B && cp <= 0x200D) ||
    (cp >= 0x2060 && cp <= 0x2065) ||
    (cp >= 0x206A && cp <= 0x206F) ||
    cp == 0xFEFF;

bool _isAuthorityMark(int c) =>
    c == 0x2F || c == 0x3F || c == 0x23 || c == 0x3A;

bool _isTrimMark(int c) =>
    c == 0x2E || c == 0x2C || c == 0x3B || c == 0x21 || c == 0x27;

bool _isB3Tail(int c) =>
    _isTrimMark(c) || c == 0x28 || c == 0x29 || c == 0x3F || c == 0x3A;

bool _isClosingQuote(int c) => c == 0x201D || c == 0x2019 || c == 0x2026;

bool _schemeRest(int c) =>
    isAsciiLetter(c) || isAsciiDigit(c) || c == 0x2B || c == 0x2E || c == 0x2D;
