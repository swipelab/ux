import 'package:ux/src/url/any_scheme.dart';
import 'package:ux/src/url/chars.dart';
import 'package:ux/src/url/darwin.dart';
import 'package:ux/src/url/email_address.dart';
import 'package:ux/src/url/match.dart';
import 'package:ux/src/url/nsdd_model.dart';
import 'package:ux/src/url/tld.dart';
import 'package:ux/src/url/web_pass.dart';

/// darwin's stage-2 state of a text: its candidates and NSDataDetector's
/// results.
typedef Stage2 = ({List<Candidate> candidates, List<NsddResult> raw});

/// Reads darwin's stage-2 state of a text.
typedef Stage2Reader = Stage2 Function(String text);

/// Reads NSDataDetector's phone results of a text, in its order.
typedef PhoneReader = List<NsddResult> Function(String text);

/// The UTF-16 units a text reads up to (p1).
const inputBound = 4096;

/// The links of [text]: darwin's stages over the stage-2 state [read] gives,
/// ux's departures from darwin's reading each an edit of that state at the
/// stage it changes. Each segment that holds a link trigger or a phone reads
/// alone, with the unit before it and three after. A segment is a token, a
/// run of units other than tab, LF, FF, CR and space, or a run of tokens
/// that one of the phones [phones] reads joins.
List<UrlMatch> readLinks(
  String text,
  Stage2Reader read, {
  PhoneReader? phones,
}) {
  if (text.length > inputBound) {
    text = text.substring(0, boundOf(text, phones?.call(text) ?? const []));
  }
  if (!hasTrigger(text) || !hasSigil(text)) return const [];
  return _Run(read).links(text, phones?.call(text) ?? const []);
}

/// Whether the UTF-16 unit [c] ends a token: tab, LF, FF, CR or space.
bool endsToken(int c) => c == 0x20 || (c >= 0x09 && c <= 0x0D && c != 0x0B);

/// p1: the units of [text] it reads, all of them up to [inputBound], else
/// those before its last tab, LF, FF, CR or space at or before its
/// [inputBound]th unit that none of [phones] spans.
int boundOf(String text, List<NsddResult> phones) {
  if (text.length <= inputBound) return text.length;
  var k = phones.length;
  for (var w = inputBound - 1; w >= 0; w--) {
    if (!endsToken(text.codeUnitAt(w))) continue;
    while (k > 0 && phones[k - 1].start >= w) {
      k--;
    }
    if (k > 0 && phones[k - 1].end > w) continue;
    return w;
  }
  return 0;
}

/// Whether [text] holds a link trigger: a '.' or ':' at which [triggerAt]
/// holds, or an ASCII '(', '+' or '0' at its start or after a phone filter
/// space, in a text of seven ASCII or fullwidth digits.
bool hasTrigger(String text) {
  var digits = 0;
  var phone = false;
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (c > 0x3A) {
      if (c >= 0xFF10 && c <= 0xFF19) digits++;
    } else if (c == 0x2E || c == 0x3A) {
      if (triggerAt(text, i)) return true;
    } else if (c >= 0x30) {
      digits++;
      if (c == 0x30 && !phone) phone = _phoneStart(text, i);
    } else if ((c == 0x28 || c == 0x2B) && !phone) {
      phone = _phoneStart(text, i);
    }
  }
  return phone && digits >= 7;
}

bool _phoneStart(String text, int i) {
  if (i == 0) return true;
  final c = text.codeUnitAt(i - 1);
  return c == 0x20 ||
      c == 0x09 ||
      c == 0x0A ||
      c == 0x0D ||
      c == 0xA0 ||
      c == 0x3000 ||
      c == 0x2028 ||
      c == 0x2029;
}

/// Whether the '.' or ':' at [i] of [text] is a link trigger: a '.' between
/// a label unit (an ASCII letter, digit, '-' or '_', or a non-ASCII unit)
/// and an ASCII letter or digit or a non-ASCII unit; a ':' after scheme
/// characters that hold an ASCII letter and before a unit above U+0020
/// outside U+007F–U+00A0.
bool triggerAt(String text, int i) {
  if (i == 0 || i + 1 >= text.length) return false;
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

/// The segments of [text] that hold a link trigger or one of [phones], in
/// order: the ones [readLinks] reads, each in its window, from the unit
/// before it to three after it.
List<(int, int)> segmentsOf(String text, List<NsddResult> phones) {
  final n = text.length;
  final out = <(int, int)>[];
  var p = 0;
  var i = 0;
  while (i < n) {
    while (i < n && endsToken(text.codeUnitAt(i))) {
      i++;
    }
    if (i == n) break;
    final start = i;
    var end = i;
    var phone = false;
    while (true) {
      while (end < n && !endsToken(text.codeUnitAt(end))) {
        end++;
      }
      int? joined;
      while (p < phones.length && phones[p].start < end) {
        if (phones[p].end > start) phone = true;
        if (phones[p].end > end && (joined == null || phones[p].end > joined)) {
          joined = phones[p].end;
        }
        p++;
      }
      if (joined == null) break;
      end = joined;
    }
    var trigger = phone;
    for (var q = start; q < end && !trigger; q++) {
      final c = text.codeUnitAt(q);
      if ((c == 0x2E || c == 0x3A) && triggerAt(text, q)) trigger = true;
    }
    if (trigger) out.add((start, end));
    i = end;
  }
  return out;
}

/// The native links stage 3 keeps in earlier segments, by the reading whose
/// cap counts them: darwin's own, the IDN stand-in's, the edited reading
/// with each link a3 cuts whole, and the edited reading.
typedef _Counts = ({int darwin, int idn, int whole, int edited});

const _Counts _none = (darwin: 0, idn: 0, whole: 0, edited: 0);

/// Text a cut other than an invisible space's removes from a link, read as
/// a text of its own.
typedef _Region = ({int start, int from, int to});

/// Text an invisible space cuts off [whole], the link as that cut finds it,
/// at stage 2 or, where [stage7], stage 7; [link] is what the cuts leave of
/// it.
typedef _CutOff = ({UrlMatch whole, UrlMatch? link, int from, bool stage7});

typedef _State = ({List<Candidate> cands, List<UrlMatch> any});

/// Where an invisible space cuts an email or phone, and what the cut keeps.
typedef _AddressCut = ({int at, UrlMatch? kept});

class _Run {
  _Run(this._read);

  final Stage2Reader _read;
  final _readings = <String, Stage2>{};

  Stage2 reading(String text) => _readings[text] ??= _read(text);

  /// The links of [text], whose phones are [phones]: each segment read in
  /// its window, then the cap, URL finishing, the phone filter and the
  /// any-scheme merge over their links in order.
  List<UrlMatch> links(String text, List<NsddResult> phones) {
    final native = <UrlMatch>[];
    final any = <UrlMatch>[];
    var before = _none;
    for (final (start, end) in segmentsOf(text, phones)) {
      final from = start == 0 ? 0 : start - 1;
      final to = end + 3 > text.length ? text.length : end + 3;
      final window = _Text(
        this,
        text.substring(from, to),
        level: 0,
        start: start - from,
        end: end - from,
        before: before,
      );
      final read = window.read();
      native.addAll(read.native.map((l) => _shift(l, from)));
      any.addAll(read.any.map((l) => _shift(l, from)));
      final counts = window.counts(read.native.length);
      before = (
        darwin: before.darwin + counts.darwin,
        idn: before.idn + counts.idn,
        whole: before.whole + counts.whole,
        edited: before.edited + counts.edited,
      );
    }
    return finish(text, native, any);
  }
}

UrlMatch _shift(UrlMatch l, int by) =>
    UrlMatch(start: l.start + by, end: l.end + by, url: l.url, kind: l.kind);

/// One text the edits read: a segment's window, whose segment is [start] to
/// [end], at level 0, a remainder of it at level 1 and a remainder of that
/// at level 2.
class _Text {
  _Text(
    this.run,
    this.text, {
    required this.level,
    this.start = 0,
    int? end,
    this.before = _none,
  }) : end = end ?? text.length;

  final _Run run;
  final String text;
  final int level;
  final int start;
  final int end;
  final _Counts before;

  late final Stage2 r = run.reading(text);
  late final PathIndex index = PathIndex(text);

  int? _idnKept;
  int? _wholeKept;

  bool inSegment(int i) => start <= i && i < end;

  /// The links of the segment after stage 3: its native links, its
  /// any-scheme links that no cut covers.
  ({List<UrlMatch> native, List<UrlMatch> any}) read() {
    final state = edited();
    final st3 = stage3(index, [
      for (final x in state.cands) x.link,
    ], everyKind: true);
    final cuts = [...st3.cuts]..sort();
    return (
      native: st3.kept,
      any: [
        for (final l in state.any)
          if (!index.covers(cuts, l)) l,
      ],
    );
  }

  /// The segment's native links in each reading a later segment's cap
  /// counts, [edited] of them in the edited reading.
  _Counts counts(int edited) {
    final darwin = _keptIn(
      stage3(index, [
        for (final c in r.candidates)
          if (inSegment(c.link.start)) c.link,
      ]).kept,
    );
    return (
      darwin: darwin,
      idn: _idnKept ?? darwin,
      whole: _wholeKept ?? edited,
      edited: edited,
    );
  }

  int _keptIn(List<UrlMatch> kept) =>
      kept.where((l) => inSegment(l.start)).length;

  /// darwin's reading of [s], a stand-in of this text, whose cap counts
  /// [base] native links before this segment, and how many native links of
  /// the segment stage 3 keeps in it. A window's stand-in passes stage 1
  /// with the text it is cut from.
  ({List<UrlMatch> links, int kept}) darwinOf(String s, int base) {
    if (level > 0 && (s.isEmpty || !hasSigil(s))) {
      return (links: const [], kept: 0);
    }
    final st3 = stage3(PathIndex(s), [
      for (final c in run.reading(s).candidates) c.link,
    ]);
    return (
      links: finish(s, st3.kept, anySchemeLinks(s), cap: maxNativeLinks - base),
      kept: _keptIn(st3.kept),
    );
  }

  /// darwin's stages 3 to 7 over the candidates [cands] and the any-scheme
  /// links [any], the continuation cut skipping a candidate of every kind
  /// and an any-scheme link, and the native links stage 3 keeps.
  ({List<UrlMatch> links, int kept}) stages(
    List<UrlMatch> cands,
    List<UrlMatch> any,
  ) {
    final st3 = stage3(index, cands, everyKind: true);
    final cuts = [...st3.cuts]..sort();
    return (
      links: finish(text, st3.kept, [
        for (final l in any)
          if (!index.covers(cuts, l)) l,
      ], cap: maxNativeLinks - before.whole),
      kept: st3.kept.length,
    );
  }

  /// The edited stage-2 candidates and stage-7 any-scheme links of the
  /// segment.
  _State edited() {
    final tel = telLinks();
    var cands = <Candidate>[
      for (final x in r.candidates)
        if (inSegment(x.link.start) &&
            !(x.link.kind == UrlMatchKind.phone && _insideTel(tel, x.link)))
          x,
      for (final x in added())
        if (inSegment(x.link.start)) x,
      ...tel,
    ];
    cands = [for (final x in cands) (link: rewrite(x.link), nsdd: x.nsdd)];
    cands = [
      for (final x in cands)
        if (!dropped(x)) x,
    ];
    final regions = <_Region>[];
    final cutOffs = <_CutOff>[];
    final addresses = cutAddresses(cands);
    cands = [
      for (final x in cands)
        if (cut(x.link, regions, cutOffs, stage7: false, addresses: addresses)
            case final link?)
          (link: link, nsdd: x.nsdd),
    ];
    final webcals = {
      for (final x in r.candidates)
        if (x.nsdd &&
            text.substring(x.link.start, x.link.end).toLowerCase() ==
                'webcal:/')
          x.link.start,
    };
    final any = [
      for (final l in anySchemeLinks(text))
        if (inSegment(l.start) && !webcalWithoutHost(webcals, l))
          ?cut(l, regions, cutOffs, stage7: true),
    ];
    return remainders(cands, any, regions, cutOffs);
  }

  /// [cands] and [any] with each remainder read as a text of its own (p2),
  /// and the text an invisible space cuts off each link the reading keeps
  /// whole starting no link.
  _State remainders(
    List<Candidate> cands,
    List<UrlMatch> any,
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
      final subCands = <Candidate>[];
      final subAny = <UrlMatch>[];
      for (final region in read) {
        final sub = _Text(
          run,
          ' ${text.substring(region.from, region.to)}',
          level: level + 1,
        ).edited();
        final by = region.from - 1;
        for (final x in sub.cands) {
          subCands.add((link: _shift(x.link, by), nsdd: x.nsdd));
        }
        subAny.addAll(sub.any.map((l) => _shift(l, by)));
      }
      cands = [
        for (final x in cands)
          if (!replaced(x.link.start)) x,
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
    final removed = <UrlMatch, int>{};
    for (final o in live) {
      if (o.link case final link?) removed[link] = (removed[link] ?? 0) + 1;
    }
    List<UrlMatch> restored(Iterable<UrlMatch> links, bool stage7) => [
      for (final l in links)
        if (_take(removed, l)) l,
      for (final o in live)
        if (o.stage7 == stage7) o.whole,
    ];
    final wholeCands = restored(cands.map((x) => x.link), false);
    final wholeAny = restored(any, true);
    final whole = stages(wholeCands, wholeAny);
    if (level == 0) _wholeKept = whole.kept;
    final spans = {for (final l in whole.links) (l.start, l.end)};
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
        for (final x in cands)
          if (!inside(x.link.start)) x,
      ],
      any: [
        for (final l in any)
          if (!inside(l.start)) l,
      ],
    );
  }

  List<Candidate> added() => [
    ...emailAddress(),
    for (final link in idnLinks()) (link: link, nsdd: false),
    ...glueLinks(),
    ...afterCfRuns(),
  ];

  /// Each Patterns.EMAIL_ADDRESS match whose domain is an IPv4 address or
  /// ends in a listed TLD, as an email.
  List<Candidate> emailAddress() => [
    for (final m in emailAddressMatches(text))
      if (onListedTld(emailDomain(text.substring(m.start, m.end))!))
        (
          link: UrlMatch(
            start: m.start,
            end: m.end,
            kind: UrlMatchKind.email,
            url:
                'mailto:${text.substring(m.start, m.at).replaceAll('%', '%25')}'
                '@${text.substring(m.at + 1, m.end)}',
          ),
          nsdd: false,
        ),
  ];

  /// The bare hosts with a non-ASCII label that darwin reads in the text
  /// with each letter or mark of a label outside ASCII and the unspaced
  /// scripts as 'q' and each such digit as '0', and in that text with every
  /// listed TLD of the segment after a run's first label as written where
  /// NSDataDetector's bare-host set holds it, else that set's ASCII TLD of
  /// its length (p3).
  List<UrlMatch> idnLinks() {
    final runs = labelRuns();
    if (runs.isEmpty) return const [];
    final main = StringBuffer();
    var at = 0;
    var changed = false;
    final replaced = <int>[];
    for (final (start, end) in runs) {
      main.write(text.substring(at, start));
      for (var i = start; i < end;) {
        final cp = cpAt(text, i);
        final w = width(cp);
        if (cp >= 0x80 && !isUnspaced(cp) && (isLetter(cp) || isMark(cp))) {
          main.write('q' * w);
          replaced.add(i);
          changed = true;
        } else if (cp >= 0x80 && !isUnspaced(cp) && isDigit(cp)) {
          main.write('0' * w);
          changed = true;
        } else {
          main.write(text.substring(i, i + w));
        }
        i += w;
      }
      at = end;
    }
    main.write(text.substring(at));
    final standIn = main.toString();
    final out = <UrlMatch>[];
    void take(
      String s,
      List<UrlMatch> reading,
      int? Function(int)? map,
      Set<int>? hostEnds,
    ) {
      for (final l in reading) {
        if (l.kind != UrlMatchKind.web ||
            l.url != 'http://${s.substring(l.start, l.end)}') {
          continue;
        }
        final sliceEnd = _hostOf(s.substring(l.start, l.end)).length + l.start;
        if (hostEnds != null && !hostEnds.contains(sliceEnd)) continue;
        final start = map == null ? l.start : map(l.start);
        final end = map == null ? l.end : map(l.end);
        if (start == null || end == null) continue;
        final slice = text.substring(start, end);
        final host = _hostOf(slice);
        if (host.codeUnits.every((u) => u < 0x80)) continue;
        if (b1Shape(host.split('.'))) continue;
        out.add(
          UrlMatch(
            start: start,
            end: end,
            url: 'http://$slice',
            kind: UrlMatchKind.web,
          ),
        );
      }
    }

    if (changed) {
      final d = darwinOf(standIn, before.idn);
      _idnKept = d.kept;
      take(standIn, d.links, null, null);
    }
    final swaps = <(int, int, String)>[];
    for (final (start, end) in runs) {
      if (!inSegment(start)) continue;
      var labelStart = start;
      var first = true;
      for (var i = start; i <= end; i++) {
        if (i < end && text.codeUnitAt(i) != 0x2E) continue;
        final label = text.substring(labelStart, i);
        if (!first && isTld(label)) {
          final held = nsddBareTlds.contains(label.toLowerCase());
          final k = _lastAtOrBefore(replaced.length, (k) => replaced[k], i - 1);
          final replacedLetter = k != null && replaced[k] >= labelStart;
          if (!held || replacedLetter) {
            swaps.add((
              labelStart,
              i,
              held ? label : _asciiTldOf(label.length),
            ));
          }
        }
        first = false;
        labelStart = i + 1;
      }
    }
    if (swaps.isEmpty) return out;
    final s = StringBuffer();
    final tldEnds = <int>{};
    at = 0;
    var shift = 0;
    for (final (from, to, tld) in swaps) {
      s
        ..write(standIn.substring(at, from))
        ..write(tld);
      tldEnds.add(from + shift + tld.length);
      shift += tld.length - (to - from);
      at = to;
    }
    s.write(standIn.substring(at));
    final swapped = s.toString();
    take(swapped, darwinOf(swapped, before.idn).links, (q) {
      var by = 0;
      for (final (from, to, tld) in swaps) {
        final start = from + by;
        if (q <= start) return q - by;
        if (q < start + tld.length) return null;
        by += tld.length - (to - from);
      }
      return q - by;
    }, tldEnds);
    return out;
  }

  /// The IDN stand-in's runs of the text: letters, marks and digits with
  /// '-', '_' and '.', from a letter or digit to the last letter, mark or
  /// digit, that hold a non-ASCII character.
  List<(int, int)> labelRuns() {
    final runs = <(int, int)>[];
    bool runChar(int cp) =>
        isLetterMarkDigit(cp) || cp == 0x2D || cp == 0x5F || cp == 0x2E;
    var i = 0;
    while (i < text.length) {
      final cp = cpAt(text, i);
      if (!runChar(cp)) {
        i += width(cp);
        continue;
      }
      final stretch = i;
      var end = i;
      while (end < text.length) {
        final e = cpAt(text, end);
        if (!runChar(e)) break;
        end += width(e);
      }
      var start = stretch;
      while (start < end) {
        final s = cpAt(text, start);
        if (isLetter(s) || isDigit(s)) break;
        start += width(s);
      }
      var last = end;
      while (last > start && !isLetterMarkDigit(cpBefore(text, last))) {
        last -= width(cpBefore(text, last));
      }
      if (last > start && _holdsNonAscii(start, last)) runs.add((start, last));
      i = end;
    }
    return runs;
  }

  bool _holdsNonAscii(int from, int to) {
    for (var i = from; i < to; i++) {
      if (text.codeUnitAt(i) >= 0x80) return true;
    }
    return false;
  }

  /// The web links darwin reads at each `tel:` in any case of the segment in
  /// the text with every such `tel` as `sms` (p3), their URL their text.
  List<Candidate> telLinks() {
    final ats = <int>[];
    for (var i = start; i + 3 < end; i++) {
      if (text.codeUnitAt(i + 3) == 0x3A &&
          text.codeUnitAt(i) | 0x20 == 0x74 &&
          text.codeUnitAt(i + 1) | 0x20 == 0x65 &&
          text.codeUnitAt(i + 2) | 0x20 == 0x6C) {
        ats.add(i);
      }
    }
    if (ats.isEmpty) return const [];
    final units = text.codeUnits.toList();
    for (final at in ats) {
      for (var i = 0; i < 3; i++) {
        units[at + i] = _sms(text.codeUnitAt(at + i), i);
      }
    }
    final starts = ats.toSet();
    return [
      for (final l in darwinOf(
        String.fromCharCodes(units),
        before.darwin,
      ).links)
        if (starts.contains(l.start) && l.kind == UrlMatchKind.web)
          (
            link: UrlMatch(
              start: l.start,
              end: l.end,
              url: text.substring(l.start, l.end),
              kind: UrlMatchKind.web,
            ),
            nsdd: false,
          ),
    ];
  }

  static int _sms(int unit, int i) =>
      'sms'.codeUnitAt(i) - (unit < 0x61 ? 0x20 : 0);

  /// The host-only candidates darwin reads with every character of the
  /// segment after a host's '.' as spaces (p3), where letterCharacterSet
  /// holds that character and general category L does not, each ending at
  /// such a '.'.
  List<Candidate> glueLinks() {
    final dots = <int>{};
    final units = text.codeUnits.toList();
    for (var at = start; at + 1 < end; at++) {
      if (text.codeUnitAt(at) != 0x2E) continue;
      final cp = cpAt(text, at + 1);
      if (!isMark(cp) || isLetter(cp) || isUnspaced(cp)) continue;
      dots.add(at);
      units.fillRange(at + 1, at + 1 + width(cp), 0x20);
    }
    if (dots.isEmpty) return const [];
    final s = String.fromCharCodes(units);
    return [
      for (final x in run.reading(s).candidates)
        if (dots.contains(x.link.end) &&
            _bare(s, x.link) &&
            _hostOnly(s, x.link))
          (link: x.link, nsdd: false),
    ];
  }

  /// The candidates with no scheme darwin reads right after a Cf run that an
  /// unspaced-script character precedes, with every such run of the segment
  /// as spaces (p3).
  List<Candidate> afterCfRuns() {
    final ends = <int>{};
    final units = text.codeUnits.toList();
    var i = start;
    while (i < end) {
      final cp = cpAt(text, i);
      if (!isFormat(cp)) {
        i += width(cp);
        continue;
      }
      final from = i;
      while (i < text.length && isFormat(cpAt(text, i))) {
        i += width(cpAt(text, i));
      }
      if (from == 0 || !isUnspaced(cpBefore(text, from))) continue;
      ends.add(i);
      units.fillRange(from, i, 0x20);
    }
    if (ends.isEmpty) return const [];
    final s = String.fromCharCodes(units);
    return [
      for (final x in run.reading(s).candidates)
        if (ends.contains(x.link.start) && _bare(s, x.link))
          (link: x.link, nsdd: false),
    ];
  }

  UrlMatch rewrite(UrlMatch link) {
    if (link.kind == UrlMatchKind.web &&
        _bare(text, link) &&
        text.codeUnitAt(link.start) == 0x201C) {
      link = UrlMatch(
        start: link.start + 1,
        end: link.end,
        url: 'http://${text.substring(link.start + 1, link.end)}',
        kind: UrlMatchKind.web,
      );
    }
    if (link.kind == UrlMatchKind.web) link = fullwidthPort(link);
    if (link.kind == UrlMatchKind.phone) {
      final raw = _rawPhones[link.start];
      if (raw != null && raw.end == link.end) {
        if (_extensionDigits(raw.value) case final extension?) {
          final digits = _foldWidth(extension);
          if (link.url.endsWith(digits)) {
            link = UrlMatch(
              start: link.start,
              end: link.end,
              url: link.url.substring(0, link.url.length - digits.length),
              kind: UrlMatchKind.phone,
            );
          }
        }
      }
    }
    return link;
  }

  late final Map<int, NsddResult> _rawPhones = {
    for (final raw in r.raw)
      if (raw.phone) raw.start: raw,
  };

  /// [link] with its fullwidth port as ASCII digits, and a host-only link
  /// with no scheme run on over ':' and fullwidth digits that an unspaced
  /// letter follows.
  UrlMatch fullwidthPort(UrlMatch link) {
    var end = link.end;
    if (_bare(text, link) &&
        _hostOnly(text, link) &&
        end < text.length &&
        text.codeUnitAt(end) == 0x3A) {
      var e = end + 1;
      while (e < text.length && _fullwidthDigit(text.codeUnitAt(e))) {
        e++;
      }
      if (e > end + 1 && e < text.length && isUnspaced(cpAt(text, e))) {
        end = e;
      }
    }
    final slice = text.substring(link.start, end);
    final scheme = _schemePrefix(slice) ?? 0;
    final authority = scheme + _authorityOf(slice.substring(scheme)).length;
    final port = _portDigits(slice.substring(0, authority));
    if (port == null ||
        !slice.substring(port, authority).codeUnits.any(_fullwidthDigit)) {
      return end == link.end
          ? link
          : UrlMatch(
              start: link.start,
              end: end,
              url: _urlOf(text, link, end),
              kind: UrlMatchKind.web,
            );
    }
    final folded =
        '${slice.substring(0, port)}${_foldWidth(slice.substring(port, authority))}'
        '${slice.substring(authority)}';
    return UrlMatch(
      start: link.start,
      end: end,
      url: _bare(text, link) ? 'http://$folded' : folded,
      kind: UrlMatchKind.web,
    );
  }

  bool dropped(Candidate x) {
    final link = x.link;
    final slice = text.substring(link.start, link.end);
    if (link.kind == UrlMatchKind.email) {
      return switch (emailDomain(slice)) {
        final domain? => !onListedTld(domain),
        null => false,
      };
    }
    if (link.kind != UrlMatchKind.web) return false;
    if (schemeAloneBeforeInvisible(link)) return true;
    if (x.nsdd && slice.toLowerCase() == 'webcal:/') return true;
    if (schemeSlashOutsideGrammar(link)) return true;
    final end = link.end;
    final isBare = _bare(text, link);
    if (text.startsWith('://', end) && isBare) return true;
    if (!isBare) return false;
    final host = _hostOf(slice);
    final labels = host.split('.');
    final next = end < text.length ? cpAt(text, end) : null;
    if (cfRunInWord(link.start)) return true;
    if (b1Shape(labels)) return true;
    if (x.nsdd &&
        next == 0x2D &&
        end + 1 < text.length &&
        (isLetter(cpAt(text, end + 1)) || isDigit(cpAt(text, end + 1)))) {
      return true;
    }
    if (next != null &&
        isWord(next) &&
        _hostOnly(text, link) &&
        !isUnspaced(next)) {
      return true;
    }
    if (_isIpv4(host) &&
        next == 0x2E &&
        end + 1 < text.length &&
        isAsciiDigit(text.codeUnitAt(end + 1))) {
      return true;
    }
    if (_isIpv4(host) &&
        host.split('.').any((o) => o.length >= 2 && o.startsWith('0'))) {
      return true;
    }
    return false;
  }

  /// Whether a Cf run that a letter, mark or digit outside the unspaced
  /// scripts precedes ends right before [start].
  bool cfRunInWord(int start) {
    var i = start;
    while (i > 0 && isFormat(cpBefore(text, i))) {
      i -= width(cpBefore(text, i));
    }
    if (i == start || i == 0) return false;
    return isSpacedLetterMarkDigit(cpBefore(text, i));
  }

  /// Whether [l] is the any-scheme link at a `webcal://` NSDataDetector reads
  /// as `webcal:/` alone at one of [webcals], whose host holds a decimal
  /// digit outside ASCII and the fullwidth forms.
  bool webcalWithoutHost(Set<int> webcals, UrlMatch l) {
    if (!webcals.contains(l.start) ||
        !_startsWithIgnoreCase(text.substring(l.start, l.end), 'webcal://')) {
      return false;
    }
    final host = _authorityOf(text.substring(l.start + 9, l.end));
    return host.runes.any(
      (cp) => isDigit(cp) && cp >= 0x80 && !(cp >= 0xFF10 && cp <= 0xFF19),
    );
  }

  /// p3: each email or phone of [cands] that an invisible space cuts, where
  /// and what the cut keeps: the longest candidate of its kind that starts
  /// where it does and ends by the cut, as darwin reads the text with every
  /// such link's cut-off text as spaces.
  Map<UrlMatch, _AddressCut> cutAddresses(List<Candidate> cands) {
    final cuts = <(UrlMatch, int)>[];
    for (final x in cands) {
      if (x.link.kind == UrlMatchKind.web) continue;
      if (invisibleCut(x.link) case final at?) cuts.add((x.link, at));
    }
    if (cuts.isEmpty) return const {};
    final units = text.codeUnits.toList();
    for (final (link, at) in cuts) {
      units.fillRange(at, link.end, 0x20);
    }
    final candidates = run.reading(String.fromCharCodes(units)).candidates;
    final out = <UrlMatch, _AddressCut>{};
    for (final (link, at) in cuts) {
      UrlMatch? kept;
      for (final x in candidates) {
        if (x.link.kind == link.kind &&
            x.link.start == link.start &&
            x.link.end <= at &&
            (kept == null || x.link.end > kept.end)) {
          kept = x.link;
        }
      }
      out[link] = (at: at, kept: kept);
    }
    return out;
  }

  /// [link] after the cuts, in their order until none changes it,
  /// each adding its region to [regions], or an invisible space's to
  /// [cutOffs]; null where a cut leaves no link. An email or phone takes the
  /// invisible space's cut alone, from [addresses].
  UrlMatch? cut(
    UrlMatch link,
    List<_Region> regions,
    List<_CutOff> cutOffs, {
    required bool stage7,
    Map<UrlMatch, _AddressCut> addresses = const {},
  }) {
    if (link.kind != UrlMatchKind.web) {
      final found = addresses[link];
      if (found == null) return link;
      cutOffs.add((
        whole: link,
        link: found.kept,
        from: found.at,
        stage7: stage7,
      ));
      return found.kept;
    }
    ({UrlMatch whole, int from})? a3;
    UrlMatch? done(UrlMatch? result) {
      if (a3 case final found?) {
        cutOffs.add((
          whole: found.whole,
          link: result,
          from: found.from,
          stage7: stage7,
        ));
      }
      return result;
    }

    var l = link;
    while (true) {
      final cut = cutAt(l);
      if (cut == null) return done(l);
      final end = stage7
          ? trimAnyScheme(text, l.start, cut.at)
          : webEnd(text, l.start, cut.at);
      if (cut.edit == _Cut.invisibleSpace) {
        a3 = (whole: l, from: end);
      } else {
        regions.add((start: l.start, from: end, to: l.end));
      }
      if (end <= l.start || _schemeAlone(text.substring(l.start, end))) {
        return done(null);
      }
      l = UrlMatch(
        start: l.start,
        end: end,
        url: stage7
            ? sanitizeUrl(text.substring(l.start, end))
            : _urlOf(text, l, end),
        kind: UrlMatchKind.web,
      );
    }
  }

  /// The first cut that ends [l] before its end, and where.
  ({_Cut edit, int at})? cutAt(UrlMatch l) {
    for (final edit in _Cut.values) {
      final at = switch (edit) {
        _Cut.hostMarks => hostMarksCut(l),
        _Cut.invisibleSpace => invisibleCut(l),
        _Cut.unopenedParen => unopenedParenCut(l),
        _Cut.unspacedInHost => unspacedCut(l),
        _Cut.trailingSymbols => trailingSymbolsCut(l),
        _Cut.closingQuotes => closingQuotesCut(l),
        _Cut.hostGrammar => hostGrammarCut(l),
      };
      if (at != null && at < l.end) return (edit: edit, at: at);
    }
    return null;
  }

  /// A scheme link's host end, where a run of `. , ; ! '` and then a '?' or
  /// ':' follow it.
  int? hostMarksCut(UrlMatch l) {
    final h = hostStart(l);
    if (h == null || h >= l.end || text.codeUnitAt(h) == 0x5B) return null;
    var q = h;
    while (q < l.end && !_isAuthorityMark(text.codeUnitAt(q))) {
      q++;
    }
    if (q >= l.end) return null;
    final c = text.codeUnitAt(q);
    if (c != 0x3F && c != 0x3A) return null;
    var r = q;
    while (r > h && _isTrimMark(text.codeUnitAt(r - 1))) {
      r--;
    }
    return r < q ? r : null;
  }

  /// The first invisible space of [l]: one [isInvisibleSpace] holds other
  /// than a ZWNJ or ZWJ between letters, marks, digits or symbols, or one
  /// [isDomainInvisibleSpace] holds in its address's domain.
  int? invisibleCut(UrlMatch l) {
    final domain = addressDomain(text.substring(l.start, l.end), l.kind);
    for (var i = l.start; i < l.end;) {
      final cp = cpAt(text, i);
      if (isInvisibleSpace(cp)) {
        final joiner =
            (cp == 0x200C || cp == 0x200D) &&
            i > 0 &&
            i + 1 < text.length &&
            isJoinable(cpBefore(text, i)) &&
            isJoinable(cpAt(text, i + 1));
        if (!joiner) return i;
      } else if (domain != null &&
          isDomainInvisibleSpace(cp) &&
          domain.$1 <= i - l.start &&
          i - l.start < domain.$2) {
        return i;
      }
      i += width(cp);
    }
    return null;
  }

  /// The domain of [slice], the text of a link of [kind], as offsets into
  /// it, where the link is an address that no `mailto:` without `//` starts:
  /// an email's after its last '@', or, written after `mailto://`, the host
  /// after any userinfo.
  (int, int)? addressDomain(String slice, UrlMatchKind kind) {
    if (_startsWithIgnoreCase(slice, 'mailto://')) {
      final authority = _authorityOf(slice.substring(9));
      final at = authority.lastIndexOf('@');
      final start = at < 0 ? 9 : 9 + at + 1;
      return (start, start + _hostOf(slice.substring(start)).length);
    }
    if (kind != UrlMatchKind.email || _writtenMailto(slice)) return null;
    final at = slice.lastIndexOf('@');
    return (at < 0 ? 0 : at + 1, slice.length);
  }

  /// Whether [link] is a scheme and at most two '/', where the text after
  /// its ':' is at most two '/' and then an invisible space.
  bool schemeAloneBeforeInvisible(UrlMatch link) {
    final slice = text.substring(link.start, link.end);
    if (!_schemeAlone(slice)) return false;
    var q = link.start + _schemeColon(slice)!;
    for (
      var n = 0;
      n < 2 && q < text.length && text.codeUnitAt(q) == 0x2F;
      n++
    ) {
      q++;
    }
    return q < text.length && isInvisibleSpace(cpAt(text, q));
  }

  /// The first ')' of [l] that it does not open and that only
  /// `. , ; ! ' ( ) ? :` follow to its end.
  int? unopenedParenCut(UrlMatch l) {
    var tail = l.end;
    while (tail > l.start && _isB3Tail(text.codeUnitAt(tail - 1))) {
      tail--;
    }
    var open = 0;
    for (var i = l.start; i < l.end; i++) {
      final c = text.codeUnitAt(i);
      if (c == 0x29) {
        if (i + 1 >= tail && open <= 0) return i;
        open--;
      } else if (c == 0x28) {
        open++;
      }
    }
    return null;
  }

  /// Before an unspaced-script character of a scheme link's host that
  /// follows another character of its label.
  int? unspacedCut(UrlMatch l) {
    final h = hostStart(l);
    if (h == null || h >= l.end || text.codeUnitAt(h) == 0x5B) return null;
    for (var i = h; i < l.end;) {
      final cp = cpAt(text, i);
      if (_isAuthorityMark(cp)) return null;
      if (i > h &&
          isUnspaced(cp) &&
          !isUnspaced(cpBefore(text, i)) &&
          text.codeUnitAt(i - 1) != 0x2E) {
        return i;
      }
      i += width(cp);
    }
    return null;
  }

  /// Where a non-word character follows [l], before the first character of
  /// its trailing non-word run that is neither ASCII nor Cf.
  int? trailingSymbolsCut(UrlMatch l) {
    if (!(l.end < text.length && !isWord(cpAt(text, l.end)))) return null;
    int? at;
    for (var i = l.end; i > l.start;) {
      final cp = cpBefore(text, i);
      if (isWord(cp)) break;
      i -= width(cp);
      if (cp >= 0x80 && !isFormat(cp)) at = i;
    }
    return at;
  }

  /// Before [l]'s trailing run of ” ’ ….
  int? closingQuotesCut(UrlMatch l) {
    var e = l.end;
    while (e > l.start && _isClosingQuote(text.codeUnitAt(e - 1))) {
      e--;
    }
    return e < l.end ? e : null;
  }

  /// Whether [link] is NSDataDetector's reading of a scheme and one '/' of a
  /// `scheme://` whose authority starts outside the host grammar.
  bool schemeSlashOutsideGrammar(UrlMatch link) {
    final end = link.end;
    if (!_schemeSlash(text.substring(link.start, end)) ||
        !text.startsWith('/', end) ||
        end + 1 >= text.length) {
      return false;
    }
    final cp = cpAt(text, end + 1);
    return !(cp == 0x2F || cp == 0x3F || cp == 0x23 || cp == 0x5B) &&
        !hostChar(end + 1);
  }

  /// Whether the character at [i] of the text is one a scheme link's host
  /// takes: a letter, mark, digit, Cf, '-', '_', '.' or a '%XX'.
  bool hostChar(int i) {
    final cp = cpAt(text, i);
    if (cp == 0x25) return _escapeAt(text, i);
    return isLetterMarkDigit(cp) ||
        isFormat(cp) ||
        cp == 0x2D ||
        cp == 0x5F ||
        cp == 0x2E;
  }

  /// At the first character of a scheme link's host, after any
  /// userinfo and outside an IP literal, that is no letter, mark, digit, Cf,
  /// '-', '_', '.' or '%XX', before its port, path, query or fragment.
  int? hostGrammarCut(UrlMatch l) {
    final h = hostStart(l);
    if (h == null || h >= l.end) return null;
    if (text.codeUnitAt(h) == 0x5B) return null;
    for (var i = h; i < l.end;) {
      final cp = cpAt(text, i);
      if (_isAuthorityMark(cp)) return null;
      if (!hostChar(i)) return i;
      i += cp == 0x25 ? 3 : width(cp);
    }
    return null;
  }

  /// Where the host of [l], a link written with a scheme and `://`, starts:
  /// after the `://` and any userinfo; null for a link without one.
  int? hostStart(UrlMatch l) {
    final slice = text.substring(l.start, l.end);
    final scheme = _schemePrefix(slice);
    if (scheme == null) return null;
    final at = _authorityOf(slice.substring(scheme)).lastIndexOf('@');
    return l.start + scheme + (at < 0 ? 0 : at + 1);
  }

  /// Whether [labels] end in an unspaced-script TLD with an ASCII label
  /// before it.
  bool b1Shape(List<String> labels) =>
      labels.length >= 2 &&
      labels.last.isNotEmpty &&
      labels.last.runes.every(isUnspaced) &&
      labels[labels.length - 2].isNotEmpty &&
      labels[labels.length - 2].codeUnits.every((u) => u < 0x80);

  /// The domain of [address], an email's text: after the '@' that ends its
  /// local part, up to a ':', without the [isDomainInvisibleSpace] code
  /// points its ToASCII form leaves out; null where no '@' ends one. After a
  /// written `mailto:`, the local part is in the first '/'-separated part of
  /// the text before any '?', and after `mailto://` any '#', that holds an
  /// '@', and ends at its last '@'; a bare address's ends at its last '@'.
  String? emailDomain(String address) {
    final String? mailbox;
    if (!_startsWithIgnoreCase(address, 'mailto:')) {
      mailbox = address;
    } else {
      final rest = address.substring(7);
      final written = _writtenMailto(address);
      var query = 0;
      while (query < rest.length &&
          !(rest.codeUnitAt(query) == 0x3F ||
              !written && rest.codeUnitAt(query) == 0x23)) {
        query++;
      }
      mailbox = rest
          .substring(0, query)
          .split('/')
          .where((part) => part.contains('@'))
          .firstOrNull;
    }
    if (mailbox == null) return null;
    final at = mailbox.lastIndexOf('@');
    if (at < 0) return null;
    final domain = mailbox.substring(at + 1);
    final colon = domain.indexOf(':');
    return String.fromCharCodes(
      (colon < 0 ? domain : domain.substring(0, colon)).runes.where(
        (cp) => !isDomainInvisibleSpace(cp),
      ),
    );
  }

  /// Whether [domain] is an IPv4 address or ends in a listed TLD in any case.
  bool onListedTld(String domain) =>
      _isIpv4(domain) || isTldInAnyCase(domain.split('.').last);
}

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

/// Whether one of [tel], sorted and apart, holds [link].
bool _insideTel(List<Candidate> tel, UrlMatch link) {
  final k = _lastAtOrBefore(tel.length, (k) => tel[k].link.start, link.start);
  return k != null && link.end <= tel[k].link.end;
}

/// Whether [removed] still counts [link], taking one count of it.
bool _take(Map<UrlMatch, int> removed, UrlMatch link) {
  final count = removed[link];
  if (count == null || count == 0) return true;
  removed[link] = count - 1;
  return false;
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

/// Whether [cp] is an invisible space a link ends before: one a darwin link
/// holds in its text and leaves out of its URL, or U+1680.
bool isInvisibleSpace(int cp) =>
    cp == 0x1680 ||
    (cp >= 0x200B && cp <= 0x200D) ||
    (cp >= 0x2060 && cp <= 0x2065) ||
    (cp >= 0x206A && cp <= 0x206F) ||
    cp == 0xFEFF;

/// Whether [cp] is an invisible space an address ends before in its domain,
/// beside [isInvisibleSpace]: a Default_Ignorable code point that the
/// domain's ToASCII form leaves out.
bool isDomainInvisibleSpace(int cp) =>
    cp == 0x00AD ||
    cp == 0x034F ||
    cp == 0x115F ||
    cp == 0x1160 ||
    cp == 0x17B4 ||
    cp == 0x17B5 ||
    (cp >= 0x180B && cp <= 0x180D) ||
    cp == 0x180F ||
    cp == 0x3164 ||
    (cp >= 0xFE00 && cp <= 0xFE0F) ||
    cp == 0xFFA0 ||
    (cp >= 0xE0100 && cp <= 0xE01EF);

/// The IDN stand-in's ASCII TLD for a label of [length] UTF-16 units outside
/// NSDataDetector's bare-host set: that set's first of [length], or `bid`.
String _asciiTldOf(int length) => nsddBareTldList.firstWhere(
  (t) => t.length == length && t.codeUnits.every((u) => u < 0x80),
  orElse: () => 'bid',
);

bool _isAuthorityMark(int c) =>
    c == 0x2F || c == 0x3F || c == 0x23 || c == 0x3A;

bool _isTrimMark(int c) =>
    c == 0x2E || c == 0x2C || c == 0x3B || c == 0x21 || c == 0x27;

bool _isB3Tail(int c) =>
    _isTrimMark(c) || c == 0x28 || c == 0x29 || c == 0x3F || c == 0x3A;

bool _isClosingQuote(int c) => c == 0x201D || c == 0x2019 || c == 0x2026;

bool _fullwidthDigit(int u) => u >= 0xFF10 && u <= 0xFF19;

String _foldWidth(String s) => String.fromCharCodes(
  s.codeUnits.map((u) => _fullwidthDigit(u) ? u - 0xFF10 + 0x30 : u),
);

bool _escapeAt(String text, int i) =>
    i + 2 < text.length &&
    text.codeUnitAt(i) == 0x25 &&
    isHex(text.codeUnitAt(i + 1)) &&
    isHex(text.codeUnitAt(i + 2));

/// Whether [link] of [text] is a web link with no scheme: its URL is
/// `http://` and its text.
bool _bare(String text, UrlMatch link) =>
    link.kind == UrlMatchKind.web &&
    link.url.length == link.end - link.start + 7 &&
    link.url.startsWith('http://') &&
    link.url.endsWith(text.substring(link.start, link.end));

/// Whether [link] of [text] has no port, path, query or fragment.
bool _hostOnly(String text, UrlMatch link) {
  for (var i = link.start; i < link.end; i++) {
    if (_isAuthorityMark(text.codeUnitAt(i))) return false;
  }
  return true;
}

/// [slice] up to its first ':', '/', '?' or '#'.
String _hostOf(String slice) {
  for (var i = 0; i < slice.length; i++) {
    if (_isAuthorityMark(slice.codeUnitAt(i))) return slice.substring(0, i);
  }
  return slice;
}

/// [rest] up to its first '/', '?' or '#'.
String _authorityOf(String rest) {
  for (var i = 0; i < rest.length; i++) {
    final c = rest.codeUnitAt(i);
    if (c == 0x2F || c == 0x3F || c == 0x23) return rest.substring(0, i);
  }
  return rest;
}

/// The URL stage 5 gives [link] of [text] ended at [end]: its text where
/// [link]'s URL is its text, else `http://` and its text.
String _urlOf(String text, UrlMatch link, int end) {
  final slice = text.substring(link.start, end);
  return _bare(text, link) ? 'http://$slice' : slice;
}

bool _schemeStart(int c) => isAsciiLetter(c);

bool _schemeRest(int c) =>
    isAsciiLetter(c) || isAsciiDigit(c) || c == 0x2B || c == 0x2E || c == 0x2D;

/// The length of the `scheme://` that starts [slice].
int? _schemePrefix(String slice) {
  if (slice.isEmpty || !_schemeStart(slice.codeUnitAt(0))) return null;
  var i = 1;
  while (i < slice.length && _schemeRest(slice.codeUnitAt(i))) {
    i++;
  }
  return slice.startsWith('://', i) ? i + 3 : null;
}

/// The length of the scheme and its ':' that start [slice].
int? _schemeColon(String slice) {
  if (slice.isEmpty || !_schemeStart(slice.codeUnitAt(0))) return null;
  var i = 1;
  while (i < slice.length && _schemeRest(slice.codeUnitAt(i))) {
    i++;
  }
  return slice.startsWith(':', i) ? i + 1 : null;
}

/// Whether [slice] is a scheme, its ':' and at most two '/'.
bool _schemeAlone(String slice) {
  final colon = _schemeColon(slice);
  if (colon == null) return false;
  final rest = slice.length - colon;
  return rest <= 2 && slice.substring(colon).codeUnits.every((c) => c == 0x2F);
}

/// Whether [slice] is a scheme, its ':' and one '/'.
bool _schemeSlash(String slice) {
  final colon = _schemeColon(slice);
  return colon != null && slice.length == colon + 1 && slice.endsWith('/');
}

bool _startsWithIgnoreCase(String s, String prefix) =>
    s.length >= prefix.length &&
    s.substring(0, prefix.length).toLowerCase() == prefix;

/// Whether [slice] starts with `mailto:` in any case and no `//` after it.
bool _writtenMailto(String slice) =>
    _startsWithIgnoreCase(slice, 'mailto:') && !slice.startsWith('//', 7);

/// Whether [s] is four dot-separated runs of one to three ASCII digits.
bool _isIpv4(String s) {
  final parts = s.split('.');
  return parts.length == 4 &&
      parts.every(
        (p) => p.isNotEmpty && p.length <= 3 && p.codeUnits.every(isAsciiDigit),
      );
}

/// Where the ':' and port of ASCII or fullwidth digits that end [authority]
/// start their digits.
int? _portDigits(String authority) {
  var i = authority.length;
  while (i > 0 &&
      (isAsciiDigit(authority.codeUnitAt(i - 1)) ||
          _fullwidthDigit(authority.codeUnitAt(i - 1)))) {
    i--;
  }
  return i < authority.length && i > 0 && authority.codeUnitAt(i - 1) == 0x3A
      ? i
      : null;
}

/// The digits after the last ';' that end a raw phone string, ASCII or
/// fullwidth.
String? _extensionDigits(String value) {
  var i = value.length;
  while (i > 0 &&
      (isAsciiDigit(value.codeUnitAt(i - 1)) ||
          _fullwidthDigit(value.codeUnitAt(i - 1)))) {
    i--;
  }
  return i < value.length && i > 0 && value.codeUnitAt(i - 1) == 0x3B
      ? value.substring(i)
      : null;
}
