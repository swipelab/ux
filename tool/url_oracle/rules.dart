// The prediction: darwin's stages, each ledger entry and answered question
// an edit of their state at the stage the planspec's edit table names, and
// darwin's own later stages over the edited state.
import 'dart:io';
import 'dart:typed_data';

import 'props.dart';
import 'stages.dart';
import 'wire.dart';

/// The ledger's edits in order, each with its class's name in the report.
const ledger = <(String, String)>[
  ('a1', 'a1: marks before a ? or : after a host'),
  ('a2', 'a2: a Cf run inside a word starts no bare host'),
  ('a3', 'a3: an invisible space ends a link'),
  ('b1', 'b1: an ASCII label under an unspaced-script TLD'),
  ('b2', 'b2: the continuation cut over every kind'),
  ('b3', "b3: an unopened ')'"),
  ('b4', 'b4: EMAIL_ADDRESS'),
  ('b5', 'b5: an IDN first label outside the unspaced scripts'),
  ('b6', "b6: NSDataDetector's host cut inside a label"),
  ('b7', 'b7: a TLD glued to a word character'),
  ('b8', 'b8: a webcal:// with no host'),
  ('b9', "b9: unspaced letters after a scheme link's host"),
  ('b10', 'b10: a trailing non-ASCII symbol run'),
  ('b11', 'b11: a trailing curly quote or ellipsis'),
  ('b12', 'b12: a fullwidth-digit port'),
  ('b13', 'b13: a written tel: URI'),
  ('b14', 'b14: a fifth number'),
  ('b15', 'b15: the glue letter is category L'),
  ('b16', "b16: an email's domain ends in a real TLD"),
  ('b17', 'b17: a Cf run after unspaced-script text'),
  ('question 1', "question 1: a host right before '://'"),
  ('question 2', 'question 2: a leading-zero octet'),
  ('question 3', "question 3: a phone extension's URL"),
  ('question 4', "question 4: a scheme link's host characters"),
  ('question 6', 'question 6: a non-ASCII label beyond b5'),
  ('Unicode', 'Unicode: a code point the tables and macOS 26.4 disagree on'),
  ('new TLDs', "new TLDs: a TLD newer than the oracle's list"),
  ('p1', 'p1: the input bound'),
  ('p2', 'p2: the remainder read'),
  ('p3', 'p3: stand-ins per segment'),
  ('p4', "p4: NSDataDetector's reading per segment"),
];

/// The edits of class p, each a departure in how another edit reads.
const performanceEdits = {'p1', 'p2', 'p3', 'p4'};

/// The units a text reads up to, by p1.
const inputBound = 4096;

/// Every edit of [ledger].
final allEdits = {for (final (e, _) in ledger) e};

/// The named conjuncts of the edits' conditions, of the IDN stand-in and of
/// the remainder read.
const conjuncts = [
  'a1:scheme',
  'a2:cf',
  'a2:spaced',
  'a3:joiner',
  'a3:domain',
  'a3:mailto',
  'a3:cutOff',
  'a3:kept',
  'a3:follows',
  'b1:ascii',
  'b4:b16',
  'b5:b1',
  'b6:nsdd',
  'b6:letterDigit',
  'b7:hostOnly',
  'b7:spaced',
  'b8:digits',
  'b9:label',
  'b10:follow',
  'b10:cf',
  'b13:phones',
  'b14:digit',
  'b16:at',
  'b16:toAscii',
  'b17:unspaced',
  'q1:bare',
  'q2:quad',
  'q4:literal',
  'idn:inSet',
  'idn:markStart',
  'cut:remainder',
  'p4:phones',
  'p4:overlap',
  'p4:standIn',
];

/// The entries of tool/url_data's newest TLD list that [oracleTlds] lacks,
/// in lowercase.
Set<String> newTlds(String uxRoot, Set<String> oracleTlds) {
  final lists =
      Directory('$uxRoot/tool/url_data')
          .listSync()
          .whereType<File>()
          .where((f) => RegExp(r'tlds-\d+\.txt$').hasMatch(f.path))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return {
    for (final line in lists.last.readAsLinesSync())
      if (line.isNotEmpty &&
          !line.startsWith('#') &&
          !oracleTlds.contains(line.toLowerCase()))
        line.toLowerCase(),
  };
}

/// The edits a prediction applies and the conjuncts it leaves out.
class Variant {
  /// A prediction with [edits], each condition without [relaxed].
  const Variant(this.edits, [this.relaxed = const {}]);

  /// The edits applied.
  final Set<String> edits;

  /// The conjuncts left out.
  final Set<String> relaxed;
}

/// What the edits read beside a text.
class RuleData {
  /// The edits' data: Unicode 17.0.0's and macOS 26.4's [characters], the
  /// oracle commit's [tlds] in lowercase with its Unicode labels,
  /// NSDataDetector's bare-host TLDs [nsddBare] as src/tld.h writes them, in
  /// its order, and the [newTlds] tool/url_data adds.
  RuleData(
    this.characters, {
    required this.tlds,
    required this.nsddBare,
    required this.newTlds,
  }) : _nsddBare = {for (final t in nsddBare) t.toLowerCase()};

  /// The character classes.
  final CharacterClasses characters;

  /// The oracle commit's TLDs, lowercase.
  final Set<String> tlds;

  /// The TLDs NSDataDetector links `see bücher.<tld> x` on.
  final List<String> nsddBare;

  /// The TLDs newer than the oracle's, lowercase.
  final Set<String> newTlds;

  final Set<String> _nsddBare;

  /// Whether NSDataDetector's bare-host set holds [tld], in any case.
  bool inNsddBare(String tld) => _nsddBare.contains(tld.toLowerCase());

  /// Whether [label] is a listed TLD as step 3 matches a bare host's: in
  /// lowercase as written, or in any case for com, edu, gov, net and org.
  bool listed(String label) =>
      tlds.contains(label) ||
      const {'com', 'edu', 'gov', 'net', 'org'}.contains(label.toLowerCase());

  /// The representative of [cp] where `props` lists it: a code point whose
  /// macOS classes are [cp]'s Unicode 17.0.0 classes.
  int? representative(int cp) {
    if (!characters.differences.contains(cp)) return null;
    for (final r in const [0x10480, 0xE000, 0x0001, 0x0086]) {
      if (characters.macClassesOf(r) == characters.unicodeClassesOf(cp)) {
        return r;
      }
    }
    return null;
  }

  /// The oracle TLD that stands in for the new TLD [label]: one of its
  /// script class, unspaced or not, that NSDataDetector's bare-host set
  /// lacks, of its length where one is.
  String substituteTld(String label) {
    final unspacedLabel = label.runes.every(unspaced);
    final ascii = label.codeUnits.every((u) => u < 0x80);
    final fits = [
      for (final t in tlds)
        if (t != label &&
            !newTlds.contains(t) &&
            !t.startsWith('xn--') &&
            !inNsddBare(t) &&
            t.runes.every(unspaced) == unspacedLabel &&
            t.codeUnits.every((u) => u < 0x80) == ascii)
          t,
    ]..sort();
    return fits.firstWhere(
      (t) => t.length == label.length,
      orElse: () => fits.first,
    );
  }

  /// Each new TLD of [text] that ends a host or an address's domain, with
  /// the oracle TLD that stands in for it.
  List<(int, int, String)> newTldSwaps(String text) {
    final out = <(int, int, String)>[];
    if (newTlds.isEmpty) return out;
    bool labelChar(int cp) =>
        characters.letters.contains(cp) ||
        characters.marks.contains(cp) ||
        characters.digits.contains(cp) ||
        cp == 0x2D;
    for (
      var dot = text.indexOf('.');
      dot >= 0;
      dot = text.indexOf('.', dot + 1)
    ) {
      if (dot == 0 || !labelChar(cpBefore(text, dot))) continue;
      var end = dot + 1;
      while (end < text.length && labelChar(cpAt(text, end))) {
        end += width(cpAt(text, end));
      }
      final label = text.substring(dot + 1, end);
      if (label.isEmpty || !newTlds.contains(label)) continue;
      out.add((dot + 1, end, substituteTld(label)));
    }
    return out;
  }

  /// Whether a new TLD ends a host or an address's domain in [text].
  bool holdsNewTld(String text) => newTldSwaps(text).isNotEmpty;

  /// The IDN stand-in's ASCII TLD for a label of [length] UTF-16 units
  /// outside NSDataDetector's set: that set's first of [length], or `bid`.
  String asciiTldOf(int length) => nsddBare.firstWhere(
    (t) => t.length == length && t.codeUnits.every((u) => u < 0x80),
    orElse: () => 'bid',
  );
}

/// A predicted reading, the spans it leaves unpredicted, and the conjuncts
/// whose leaving out could change it.
class Prediction {
  /// [links], with [unpredicted] spans, from a run in which [touched]'s
  /// conjuncts were false somewhere.
  const Prediction(this.links, this.unpredicted, this.touched);

  /// The predicted links.
  final List<Link> links;

  /// Spans where no link is predicted and any link departs.
  final List<(int, int)> unpredicted;

  /// The conjuncts found false in the run.
  final Set<String> touched;
}

/// Predicts readings from probe-stages readings it is given, recording each
/// text it needs and lacks in [missing].
class Predictor {
  /// A predictor over [data].
  Predictor(this.data);

  /// The edits' data.
  final RuleData data;

  /// probe-stages readings by text.
  final Map<String, ProbeReading> readings = {};

  /// The texts a prediction needed and found no reading for.
  final Set<String> missing = {};

  /// [text]'s prediction under [variant], or null where a reading is
  /// missing.
  Prediction? predict(String text, Variant variant) {
    final run = _Run(this, variant);
    final links = run.predict(text);
    return run.incomplete
        ? null
        : Prediction(links, run.unpredicted, run.touched);
  }

  ProbeReading? _reading(String text) {
    final r = readings[text];
    if (r == null) missing.add(text);
    return r;
  }
}

/// A stage-2 candidate: a link and whether NSDataDetector gave it.
typedef _Cand = ({Link link, bool nsdd});

/// Text a cut other than a3's removes from a link, read as text after a
/// link's end.
typedef _Region = ({int start, int from, int to});

/// Text a3's cut removes from [whole], the link as a3 finds it, at stage 2
/// or, where [stage7], stage 7; [link] is what the cuts leave of it.
typedef _CutOff = ({Link whole, Link? link, int from, bool stage7});

class _Run {
  _Run(this.p, this.variant);

  final Predictor p;
  final Variant variant;
  final touched = <String>{};
  final unpredicted = <(int, int)>[];
  var incomplete = false;

  RuleData get d => p.data;
  CharacterClasses get c => d.characters;

  bool on(String edit) => variant.edits.contains(edit);

  /// [value] for [conjunct], or true where the variant leaves it out.
  bool holds(String conjunct, bool value) {
    if (value) return true;
    touched.add(conjunct);
    return variant.relaxed.contains(conjunct);
  }

  /// Whether the variant keeps [conjunct], a step with no condition.
  bool kept(String conjunct) {
    touched.add(conjunct);
    return !variant.relaxed.contains(conjunct);
  }

  ProbeReading? reading(String text) {
    final r = p._reading(text);
    if (r == null) incomplete = true;
    return r;
  }

  List<Link>? darwinOf(String text) {
    final r = reading(text);
    return r == null ? null : darwinMatch(text, r.native);
  }

  /// p4: darwin's reading of [window], a stand-in of a segment's window,
  /// whose cap counts the [before] native links of the segments before it,
  /// and the native links stage 3 keeps in the segment from [start] to
  /// [end] of it.
  ({List<Link> links, int kept})? windowDarwinOf(
    String window,
    int before,
    int start,
    int end,
  ) {
    final r = reading(window);
    if (r == null) return null;
    final native = r.native;
    return (
      links: finish(
        window,
        native,
        anySchemeLinks(window),
        cap: maxNativeLinks - before,
      ),
      kept: native.where((l) => start <= l.start && l.start < end).length,
    );
  }

  /// p4: [own], the reading of [text], with NSDataDetector's candidates and
  /// results in each of [segments] those of the segment's window read as a
  /// text of its own, with [own]'s phones in the segment in place of the
  /// window's, each dropping the window's candidates and results it
  /// overlaps; null where a reading is missing.
  ProbeReading? perSegment(String text, ProbeReading own, Segments segments) {
    final candidates = <Candidate>[];
    final raw = <RawResult>[];
    for (final (start, end) in segments.spans) {
      bool inside(int i) => start <= i && i < end;
      final from = start == 0 ? 0 : start - 1;
      final to = end + 3 > text.length ? text.length : end + 3;
      final w = reading(text.substring(from, to));
      if (w == null) return null;
      final textPhones = [
        for (final x in own.raw)
          if (x.phone && inside(x.start)) x,
      ];
      final windowPhones = [
        for (final x in w.raw)
          if (x.phone && inside(x.start + from))
            RawResult(
              x.start + from,
              x.end + from,
              phone: true,
              value: x.value,
            ),
      ];
      final textsPhones =
          _sameResults(textPhones, windowPhones) || kept('p4:phones');
      final phones = textsPhones ? textPhones : windowPhones;
      bool dropped(int s, int e) =>
          phones.any((p) => p.start < e && s < p.end) && kept('p4:overlap');
      for (final x in w.candidates!) {
        final s = x.link.start + from;
        final e = x.link.end + from;
        if (!x.nsdd || !inside(s) || x.link.kind == 'phone' || dropped(s, e)) {
          continue;
        }
        candidates.add(
          Candidate(Link(s, e, x.link.kind, x.link.url), nsdd: true),
        );
      }
      for (final x in w.raw) {
        final s = x.start + from;
        if (x.phone || !inside(s) || dropped(s, x.end + from)) continue;
        raw.add(RawResult(s, x.end + from, phone: false, value: x.value));
      }
      raw.addAll(phones);
      if (textsPhones) {
        candidates.addAll([
          for (final x in own.candidates!)
            if (x.nsdd && x.link.kind == 'phone' && inside(x.link.start)) x,
        ]);
      } else {
        candidates.addAll([
          for (final x in w.candidates!)
            if (x.nsdd && x.link.kind == 'phone' && inside(x.link.start + from))
              Candidate(
                Link(
                  x.link.start + from,
                  x.link.end + from,
                  'phone',
                  x.link.url,
                ),
                nsdd: true,
              ),
        ]);
      }
    }
    return ProbeReading(Uint8List(0), raw, [
      ...candidates,
      for (final x in own.candidates!)
        if (!x.nsdd) x,
    ]);
  }

  List<Link> predict(String text) {
    if (on('p1') && text.length > inputBound) {
      final r = reading(text);
      if (r == null) return const [];
      text = text.substring(0, boundOf(text, r.raw));
    }
    if (text.isEmpty || !hasSigil(text)) return const [];
    final state = edited(text);
    if (state == null) return const [];
    return stages(text, [for (final x in state.cands) x.link], state.any);
  }

  /// darwin's stages 3 to 7 over the stage-2 candidates [cands] and the
  /// any-scheme links [any] of [text].
  List<Link> stages(String text, List<Link> cands, List<Link> any) {
    final st3 = stage3(text, cands, everyKind: on('b2'));
    if (on('b2')) {
      any = [
        for (final l in any)
          if (!st3.cuts.any(
            (cut) => continuesPath(text, cut.$2, l.start, l.end),
          ))
            l,
      ];
    }
    return finish(text, st3.kept, any);
  }

  /// The edited stage-2 candidates and stage-7 any-scheme links of [text],
  /// which p2 reads as a remainder at [level] 1 and as a remainder's
  /// remainder at 2.
  ({List<_Cand> cands, List<Link> any})? edited(String text, {int level = 0}) {
    final original = reading(text);
    if (original == null) return null;
    final segments = Segments(text, original.raw);
    final perSegments = on('p4') && level == 0;
    final own = perSegments ? perSegment(text, original, segments) : original;
    if (own == null) return null;
    final windows = perSegments
        ? _Windows(
            text,
            stage3(text, [for (final x in own.candidates!) x.link]).kept,
          )
        : null;
    final base = standInBase(text, own, perSegments: perSegments);
    if (base == null) return null;
    final r = base.reading;
    var cands = base.cands;
    final tel = on('b13') ? telLinks(text, segments, windows) : const <_Cand>[];
    cands = [
      for (final x in cands)
        if (!(tel ?? const []).any(
          (t) =>
              t.link.start <= x.link.start &&
              x.link.end <= t.link.end &&
              holds('b13:phones', x.link.kind == 'phone'),
        ))
          x,
      ...?added(text, segments, windows),
      ...?tel,
    ];
    cands = [for (final x in cands) (link: rewrite(text, r, x), nsdd: x.nsdd)];
    cands = [
      for (final x in cands)
        if (!dropped(text, x)) x,
    ];
    final regions = <_Region>[];
    final cutOffs = <_CutOff>[];
    final addresses = on('p3')
        ? cutAddresses(text, cands, segments, windows)
        : null;
    if (on('p3') && addresses == null) return null;
    cands = [
      for (final x in cands)
        if (cut(
              text,
              x.link,
              regions,
              cutOffs,
              stage7: false,
              addresses: addresses,
            )
            case final link?)
          (link: link, nsdd: x.nsdd),
    ];
    var any = anySchemeLinks(text);
    if (on('b8')) {
      any = [
        for (final l in any)
          if (!webcalWithoutHost(text, r, l)) l,
      ];
    }
    any = [for (final l in any) ?cut(text, l, regions, cutOffs, stage7: true)];
    return remainders(text, cands, any, regions, cutOffs, level);
  }

  /// [cands] and [any] with each region's text read as after a link's end,
  /// and the text a3 cuts off each link the reading keeps whole starting no
  /// link.
  ({List<_Cand> cands, List<Link> any})? remainders(
    String text,
    List<_Cand> cands,
    List<Link> any,
    List<_Region> regions,
    List<_CutOff> cutOffs,
    int level,
  ) {
    final read = <_Region>[];
    final p2 = on('p2');
    final order = p2
        ? ([...regions]..sort((a, b) {
            final byStart = a.from.compareTo(b.from);
            return byStart != 0
                ? byStart
                : (b.to - b.from).compareTo(a.to - a.from);
          }))
        : regions;
    for (final region in order) {
      if (region.from <= region.start || p2 && level >= 2) continue;
      if (read.any((r) => r.from <= region.from && region.from < r.to)) {
        continue;
      }
      read.add(region);
      if (!kept('cut:remainder')) continue;
      bool inside(int start) => region.from <= start && start < region.to;
      final List<_Cand> subCands;
      final List<Link> subAny;
      if (p2) {
        final sub = edited(
          ' ${text.substring(region.from, region.to)}',
          level: level + 1,
        );
        if (sub == null) return null;
        Link shifted(Link l) => Link(
          l.start - 1 + region.from,
          l.end - 1 + region.from,
          l.kind,
          l.url,
        );
        subCands = [
          for (final x in sub.cands) (link: shifted(x.link), nsdd: x.nsdd),
        ];
        subAny = [for (final l in sub.any) shifted(l)];
      } else {
        final blanked =
            '${text.substring(0, region.start)}'
            '${' ' * (region.from - region.start)}'
            '${text.substring(region.from)}';
        final sub = edited(blanked);
        if (sub == null) return null;
        subCands = sub.cands;
        subAny = sub.any;
      }
      cands = [
        for (final x in cands)
          if (!inside(x.link.start)) x,
        for (final x in subCands)
          if (inside(x.link.start)) x,
      ];
      any = [
        for (final l in any)
          if (!inside(l.start)) l,
        for (final l in subAny)
          if (inside(l.start)) l,
      ];
    }
    bool replaced(int start) =>
        read.any((r) => r.from <= start && start < r.to);
    final live = [
      for (final o in cutOffs)
        if (!replaced(o.whole.start)) o,
    ];
    if (live.isEmpty || !kept('a3:cutOff')) return (cands: cands, any: any);
    final wholeCands = [for (final x in cands) x.link];
    final wholeAny = [...any];
    for (final o in live) {
      final links = o.stage7 ? wholeAny : wholeCands;
      if (o.link != null) links.remove(o.link);
      links.add(o.whole);
    }
    final whole = stages(text, wholeCands, wholeAny);
    final cutOff = [
      for (final o in live)
        if (holds(
          'a3:kept',
          whole.any((l) => l.start == o.whole.start && l.end == o.whole.end),
        ))
          (o.from, o.whole.end),
    ];
    bool inside(int start) => cutOff.any((r) => r.$1 <= start && start < r.$2);
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

  /// The candidates and reading the edits start from: [own], or, for the
  /// Unicode and new-TLD edits, those of the stand-in with each listed code
  /// point as its representative and each new TLD as an oracle TLD of its
  /// class, mapped back to [text], the stand-in read per segment (p4) where
  /// [perSegments] holds.
  ({List<_Cand> cands, ProbeReading reading})? standInBase(
    String text,
    ProbeReading own, {
    required bool perSegments,
  }) {
    final swaps = <(int, int, String)>[];
    final unicode = <int>[];
    if (on('Unicode')) {
      for (var i = 0; i < text.length;) {
        final cp = cpAt(text, i);
        final glue = i > 0 && text[i - 1] == '.' && c.letters.contains(cp);
        final representative = d.representative(cp);
        if (representative != null && !glue) {
          swaps.add((i, i + width(cp), String.fromCharCode(representative)));
          unicode.add(i);
        }
        i += width(cp);
      }
    }
    if (on('new TLDs')) swaps.addAll(d.newTldSwaps(text));
    if (swaps.isEmpty) {
      return (
        cands: [for (final x in own.candidates!) (link: x.link, nsdd: x.nsdd)],
        reading: own,
      );
    }
    swaps.sort((a, b) => a.$1.compareTo(b.$1));
    final s = StringBuffer();
    var at = 0;
    for (final (from, to, by) in swaps) {
      s.write(text.substring(at, from));
      s.write(by);
      at = to;
    }
    s.write(text.substring(at));
    final standIn = s.toString();
    final whole = reading(standIn);
    if (whole == null) return null;
    final r = perSegments
        ? perSegment(standIn, whole, Segments(standIn, whole.raw))
        : whole;
    if (r == null) return null;
    int? back(int q) {
      var shift = 0;
      for (final (from, to, by) in swaps) {
        final start = from + shift;
        if (q <= start) return q - shift;
        if (q < start + by.length) return null;
        shift += by.length - (to - from);
      }
      return q - shift;
    }

    final cands = <_Cand>[];
    for (final x in r.candidates!) {
      final start = back(x.link.start);
      final end = back(x.link.end);
      if (start == null || end == null) continue;
      final slice = text.substring(start, end);
      final standInSlice = standIn.substring(x.link.start, x.link.end);
      var url = x.link.url;
      if (x.link.kind == 'web') {
        url = x.link.url == 'http://$standInSlice' ? 'http://$slice' : slice;
      } else if (x.link.kind == 'email') {
        if (unicode.any((u) => start <= u && u < end)) {
          unpredicted.add((start, end));
          continue;
        }
        var cursor = 0;
        var mapped = true;
        for (final (from, to, by) in swaps) {
          if (from < start || to > end) continue;
          final at = url.indexOf(by, cursor);
          if (at < 0) {
            mapped = false;
            break;
          }
          final label = text.substring(from, to);
          url = '${url.substring(0, at)}$label${url.substring(at + by.length)}';
          cursor = at + label.length;
        }
        if (!mapped) {
          unpredicted.add((start, end));
          continue;
        }
      }
      cands.add((link: Link(start, end, x.link.kind, url), nsdd: x.nsdd));
    }
    return (cands: cands, reading: r);
  }

  List<_Cand>? added(String text, Segments segments, _Windows? windows) {
    final out = <_Cand>[];
    if (on('b4')) out.addAll(emailAddress(text));
    if (on('b5') || on('question 6')) {
      final idn = idnLinks(text, segments, windows);
      if (idn == null) return null;
      for (final (link, spaced) in idn) {
        if (on(spaced ? 'b5' : 'question 6')) {
          out.add((link: link, nsdd: false));
        }
      }
    }
    if (on('b15')) {
      final glue = glueLinks(text, segments, windows);
      if (glue == null) return null;
      out.addAll(glue);
    }
    if (on('b17')) {
      final after = afterCfRuns(text, segments, windows);
      if (after == null) return null;
      out.addAll(after);
    }
    return out;
  }

  /// p4: whether [windows] reads each segment's stand-in as its window with
  /// the segment's occurrences substituted.
  bool inWindows(_Windows? windows) => windows != null && kept('p4:standIn');

  /// b4: each EMAIL_ADDRESS match b16 keeps, as an email.
  List<_Cand> emailAddress(String text) => [
    for (final m in _emailAddress.allMatches(text))
      if (holds('b4:b16', onListedTld(emailDomain(m[0]!)!)))
        (
          link: Link(
            m.start,
            m.end,
            'email',
            'mailto:${m[1]!.replaceAll('%', '%25')}@${m[2]!}',
          ),
          nsdd: false,
        ),
  ];

  /// b5 and question 6: the links of the IDN stand-in, each with whether
  /// its host's first label holds a letter outside ASCII and the unspaced
  /// scripts. Each TLD label swap reads a stand-in of its own, or, with p3,
  /// one with every swap of its segment, and, with p4, each segment reads
  /// its window's stand-ins, whose cap counts the native links the IDN
  /// stand-in's reading keeps in the segments before it.
  List<(Link, bool)>? idnLinks(
    String text,
    Segments segments,
    _Windows? windows,
  ) {
    if (labelRuns(text).isEmpty) return const [];
    if (!inWindows(windows)) {
      return idnLinksOf(text, segments, null)?.links;
    }
    final out = <(Link, bool)>[];
    var gained = 0;
    for (final span in segments.spans) {
      final (from, to) = windows!.of(span);
      final found = idnLinksOf(text.substring(from, to), null, (
        start: span.$1 - from,
        end: span.$2 - from,
        before: windows.before(span.$1) + gained,
      ));
      if (found == null) return null;
      if (found.kept case final kept?) gained += kept - windows.keptIn(span);
      for (final (l, spaced) in found.links) {
        if (l.start + from < span.$1 || l.start + from >= span.$2) continue;
        out.add((Link(l.start + from, l.end + from, l.kind, l.url), spaced));
      }
    }
    return out;
  }

  /// [idnLinks] of [s]: the whole text, its TLD label swaps grouped by its
  /// [segments], or a segment's [window], its swaps those of its segment,
  /// whose readings' cap counts the native links of the segments before it;
  /// with the native links the main stand-in's reading keeps in the segment,
  /// where it differs from [s].
  ({List<(Link, bool)> links, int? kept})? idnLinksOf(
    String s,
    Segments? segments,
    ({int start, int end, int before})? window,
  ) {
    final runs = labelRuns(s);
    final main = StringBuffer();
    var at = 0;
    var changed = false;
    final replaced = <int>{};
    for (final (start, end) in runs) {
      main.write(s.substring(at, start));
      for (var i = start; i < end;) {
        final cp = cpAt(s, i);
        final w = width(cp);
        if (cp >= 0x80 && !unspaced(cp)) {
          if (c.letters.contains(cp) || c.marks.contains(cp)) {
            main.write('q' * w);
            replaced.add(i);
            changed = true;
          } else if (c.digits.contains(cp)) {
            main.write('0' * w);
            changed = true;
          } else {
            main.write(s.substring(i, i + w));
          }
        } else {
          main.write(s.substring(i, i + w));
        }
        i += w;
      }
      at = end;
    }
    main.write(s.substring(at));
    final standIn = main.toString();
    final out = <(Link, bool)>[];
    List<Link>? darwin(String x) {
      if (window == null) return darwinOf(x);
      return windowDarwinOf(x, window.before, window.start, window.end)?.links;
    }

    void take(
      String t,
      List<Link> reading,
      int? Function(int)? map,
      Set<int>? hostEnds,
    ) {
      for (final l in reading) {
        if (l.kind != 'web' ||
            l.url != 'http://${t.substring(l.start, l.end)}') {
          continue;
        }
        final sliceEnd = hostOf(t.substring(l.start, l.end)).length + l.start;
        if (hostEnds != null && !hostEnds.contains(sliceEnd)) continue;
        final start = map == null ? l.start : map(l.start);
        final end = map == null ? l.end : map(l.end);
        if (start == null || end == null) continue;
        final slice = s.substring(start, end);
        final host = hostOf(slice);
        if (host.codeUnits.every((u) => u < 0x80)) continue;
        final labels = host.split('.');
        if (!holds('b5:b1', !b1Shape(labels))) continue;
        out.add((
          Link(start, end, 'web', 'http://$slice'),
          spacedLetter(labels.first),
        ));
      }
    }

    int? kept;
    if (changed) {
      if (window == null) {
        final w = darwinOf(standIn);
        if (w == null) return null;
        take(standIn, w, null, null);
      } else {
        final w = windowDarwinOf(
          standIn,
          window.before,
          window.start,
          window.end,
        );
        if (w == null) return null;
        kept = w.kept;
        take(standIn, w.links, null, null);
      }
    }
    final swaps = <(int, int, String)>[];
    for (final (start, end) in runs) {
      if (window != null && (start < window.start || start >= window.end)) {
        continue;
      }
      var labelStart = start;
      var first = true;
      for (var i = start; i <= end; i++) {
        if (i < end && s[i] != '.') continue;
        final label = s.substring(labelStart, i);
        if (!first && d.listed(label)) {
          final held = d.inNsddBare(label);
          final replacedLetter = replaced.any((r) => labelStart <= r && r < i);
          if (!held || replacedLetter) {
            final tld = holds('idn:inSet', !held)
                ? d.asciiTldOf(label.length)
                : label;
            swaps.add((labelStart, i, tld));
          }
        }
        first = false;
        labelStart = i + 1;
      }
    }
    final groups = !on('p3')
        ? [
            for (final swap in swaps) [swap],
          ]
        : window == null
        ? segments!.group(swaps, (swap) => swap.$1)
        : [if (swaps.isNotEmpty) swaps];
    for (final group in groups) {
      final t = StringBuffer();
      final tldEnds = <int>{};
      var at = 0;
      var shift = 0;
      for (final (from, to, tld) in group) {
        t
          ..write(standIn.substring(at, from))
          ..write(tld);
        tldEnds.add(from + shift + tld.length);
        shift += tld.length - (to - from);
        at = to;
      }
      t.write(standIn.substring(at));
      final w = darwin('$t');
      if (w == null) return null;
      take('$t', w, (q) => back(group, q), tldEnds);
    }
    return (links: out, kept: kept);
  }

  /// The offset in the original text of [q], an offset in the text with each
  /// of [swaps] in place, or null inside a swapped label.
  int? back(List<(int, int, String)> swaps, int q) {
    var shift = 0;
    for (final (from, to, tld) in swaps) {
      final start = from + shift;
      if (q <= start) return q - shift;
      if (q < start + tld.length) return null;
      shift += tld.length - (to - from);
    }
    return q - shift;
  }

  /// The IDN stand-in's runs of [text]: letters, marks and digits with '-',
  /// '_' and '.', from a letter or digit to the last letter, mark or digit,
  /// that hold a non-ASCII character.
  List<(int, int)> labelRuns(String text) {
    final runs = <(int, int)>[];
    bool labelChar(int cp) =>
        c.letters.contains(cp) || c.marks.contains(cp) || c.digits.contains(cp);
    var i = 0;
    while (i < text.length) {
      final cp = cpAt(text, i);
      if (!(labelChar(cp) || cp == 0x2D || cp == 0x5F || cp == 0x2E)) {
        i += width(cp);
        continue;
      }
      final stretch = i;
      var end = i;
      while (end < text.length) {
        final e = cpAt(text, end);
        if (!(labelChar(e) || e == 0x2D || e == 0x5F || e == 0x2E)) break;
        end += width(e);
      }
      var start = stretch;
      while (start < end) {
        final s = cpAt(text, start);
        if (c.letters.contains(s) || c.digits.contains(s)) break;
        if (c.marks.contains(s) && holds('idn:markStart', false)) break;
        start += width(s);
      }
      var last = end;
      while (last > start && !labelChar(cpBefore(text, last))) {
        last -= width(cpBefore(text, last));
      }
      if (last > start &&
          text.substring(start, last).codeUnits.any((u) => u >= 0x80)) {
        runs.add((start, last));
      }
      i = end;
    }
    return runs;
  }

  /// p4: the window the stand-in of [group], occurrences at [at] of
  /// [text], reads, as offsets in [text], with its segment's span in it and
  /// the native links of the segments before it; null where the stand-in
  /// reads all of [text].
  ({int from, int to, int start, int end, int before})? windowOf<T>(
    String text,
    List<T> group,
    int Function(T) at,
    Segments segments,
    _Windows? windows,
  ) {
    if (!inWindows(windows)) return null;
    final span = segments.spanOf(at(group.first))!;
    final (from, to) = windows!.of(span);
    return (
      from: from,
      to: to,
      start: span.$1 - from,
      end: span.$2 - from,
      before: windows.before(span.$1),
    );
  }

  /// [items], occurrences at [at], grouped by their segment of [segments]
  /// with p3, else one group each.
  List<List<T>> occurrences<T>(
    List<T> items,
    int Function(T) at,
    Segments segments,
  ) => on('p3')
      ? segments.group(items, at)
      : [
          for (final item in items) [item],
        ];

  /// b13: at each `tel:` in any case, the web link darwin reads there with
  /// that `tel` as `sms`, or, with p3, with every `tel` of its segment as
  /// `sms`, its URL its text.
  List<_Cand>? telLinks(String text, Segments segments, _Windows? windows) {
    final out = <_Cand>[];
    final ats = [
      for (var at = 0; at + 3 < text.length; at++)
        if (text.codeUnitAt(at + 3) == 0x3A &&
            text.substring(at, at + 3).toLowerCase() == 'tel')
          at,
    ];
    for (final group in occurrences(ats, (at) => at, segments)) {
      final window = windowOf(text, group, (at) => at, segments, windows);
      final from = window?.from ?? 0;
      final units = text
          .substring(from, window?.to ?? text.length)
          .codeUnits
          .toList();
      for (final at in group) {
        for (var i = 0; i < 3; i++) {
          units[at - from + i] = _sms(text.codeUnitAt(at + i), i);
        }
      }
      final s = String.fromCharCodes(units);
      final w = window == null
          ? darwinOf(s)
          : windowDarwinOf(s, window.before, window.start, window.end)?.links;
      if (w == null) return null;
      final starts = group.toSet();
      for (final l in w) {
        final start = l.start + from;
        final end = l.end + from;
        if (starts.contains(start) && l.kind == 'web') {
          out.add((
            link: Link(start, end, 'web', text.substring(start, end)),
            nsdd: false,
          ));
        }
      }
    }
    return out;
  }

  static int _sms(int unit, int i) {
    final upper = unit < 0x61;
    return 'sms'.codeUnitAt(i) - (upper ? 0x20 : 0);
  }

  /// b15's add: the host-only candidate darwin reads with the character
  /// after a host's '.' as spaces, where letterCharacterSet holds that
  /// character and Unicode 17.0.0's L does not, or, with p3, with every such
  /// character of its segment as spaces.
  List<_Cand>? glueLinks(String text, Segments segments, _Windows? windows) {
    final out = <_Cand>[];
    final ats = <int>[];
    for (var at = text.indexOf('.'); at >= 0; at = text.indexOf('.', at + 1)) {
      if (at + 1 >= text.length) break;
      final cp = cpAt(text, at + 1);
      if (!c.macLetters.contains(cp) ||
          c.letters.contains(cp) ||
          unspaced(cp)) {
        continue;
      }
      ats.add(at);
    }
    for (final group in occurrences(ats, (at) => at, segments)) {
      final window = windowOf(text, group, (at) => at, segments, windows);
      final from = window?.from ?? 0;
      final units = text
          .substring(from, window?.to ?? text.length)
          .codeUnits
          .toList();
      for (final at in group) {
        for (var i = 0; i < width(cpAt(text, at + 1)); i++) {
          units[at + 1 - from + i] = 0x20;
        }
      }
      final s = String.fromCharCodes(units);
      final r = reading(s);
      if (r == null) return null;
      final ends = {for (final at in group) at - from};
      for (final x in r.candidates!) {
        if (ends.contains(x.link.end) &&
            bare(s, x.link) &&
            hostOnly(s, x.link)) {
          out.add((link: _shifted(x.link, from), nsdd: false));
        }
      }
    }
    return out;
  }

  /// b17: the candidates with no scheme darwin reads right after a Cf run
  /// that an unspaced-script character precedes, with the run as spaces, or,
  /// with p3, with every such run of its segment as spaces.
  List<_Cand>? afterCfRuns(String text, Segments segments, _Windows? windows) {
    final out = <_Cand>[];
    final runs = <(int, int)>[];
    var i = 0;
    while (i < text.length) {
      final cp = cpAt(text, i);
      if (!c.format.contains(cp)) {
        i += width(cp);
        continue;
      }
      final start = i;
      while (i < text.length && c.format.contains(cpAt(text, i))) {
        i += width(cpAt(text, i));
      }
      if (start == 0 ||
          !holds('b17:unspaced', unspaced(cpBefore(text, start)))) {
        continue;
      }
      runs.add((start, i));
    }
    for (final group in occurrences(runs, (run) => run.$1, segments)) {
      final window = windowOf(text, group, (run) => run.$1, segments, windows);
      final from = window?.from ?? 0;
      final units = text
          .substring(from, window?.to ?? text.length)
          .codeUnits
          .toList();
      for (final (start, end) in group) {
        units.fillRange(start - from, end - from, 0x20);
      }
      final s = String.fromCharCodes(units);
      final r = reading(s);
      if (r == null) return null;
      final ends = {for (final (_, end) in group) end - from};
      for (final x in r.candidates!) {
        if (ends.contains(x.link.start) && bare(s, x.link)) {
          out.add((link: _shifted(x.link, from), nsdd: false));
        }
      }
    }
    return out;
  }

  Link rewrite(String text, ProbeReading r, _Cand x) {
    var link = x.link;
    if (on('b11') &&
        link.kind == 'web' &&
        bare(text, link) &&
        text[link.start] == '“') {
      link = Link(
        link.start + 1,
        link.end,
        'web',
        'http://${text.substring(link.start + 1, link.end)}',
      );
    }
    if (on('b12') && link.kind == 'web') link = fullwidthPort(text, link);
    if (on('question 3') && link.kind == 'phone') {
      for (final raw in r.raw) {
        if (!raw.phone || raw.start != link.start || raw.end != link.end) {
          continue;
        }
        final extension = RegExp(r';([0-9０-９]+)$').firstMatch(raw.value);
        if (extension == null) continue;
        final digits = foldWidth(extension[1]!);
        if (link.url.endsWith(digits)) {
          link = Link(
            link.start,
            link.end,
            'phone',
            link.url.substring(0, link.url.length - digits.length),
          );
        }
      }
    }
    return link;
  }

  /// b12: [link] with its fullwidth port as ASCII digits, and a host-only
  /// link with no scheme run on over ':' and fullwidth digits that an
  /// unspaced letter follows.
  Link fullwidthPort(String text, Link link) {
    var end = link.end;
    if (bare(text, link) &&
        hostOnly(text, link) &&
        end < text.length &&
        text[end] == ':') {
      var e = end + 1;
      while (e < text.length && _fullwidthDigit(text.codeUnitAt(e))) {
        e++;
      }
      if (e > end + 1 && e < text.length && unspaced(cpAt(text, e))) end = e;
    }
    final slice = text.substring(link.start, end);
    final scheme = _scheme.firstMatch(slice)?.end ?? 0;
    final authority = scheme + authorityOf(slice.substring(scheme)).length;
    final port = RegExp(r':([0-9０-９]+)$')
        .firstMatch(slice.substring(0, authority));
    if (port == null || !port[1]!.codeUnits.any(_fullwidthDigit)) {
      return end == link.end
          ? link
          : Link(link.start, end, 'web', urlOf(text, link, end));
    }
    final folded =
        '${slice.substring(0, port.start + 1)}${foldWidth(port[1]!)}'
        '${slice.substring(authority)}';
    return Link(
      link.start,
      end,
      'web',
      bare(text, link) ? 'http://$folded' : folded,
    );
  }

  bool dropped(String text, _Cand x) {
    final link = x.link;
    final slice = text.substring(link.start, link.end);
    if (link.kind == 'email') {
      return on('b16') &&
          switch (emailDomain(slice)) {
            final domain? => !onListedTld(domain),
            null => holds('b16:at', false),
          };
    }
    if (link.kind != 'web') return false;
    if (on('a3') && schemeAloneBeforeInvisible(text, link)) return true;
    if (on('b8') && x.nsdd && slice.toLowerCase() == 'webcal:/') return true;
    if (on('question 4') && schemeSlashOutsideGrammar(text, link)) return true;
    final end = link.end;
    final isBare = bare(text, link);
    if (on('question 1') &&
        text.startsWith('://', end) &&
        holds('q1:bare', isBare)) {
      return true;
    }
    if (!isBare) return false;
    final host = hostOf(slice);
    final labels = host.split('.');
    final next = end < text.length ? cpAt(text, end) : null;
    if (on('a2') && cfRunInWord(text, link.start)) return true;
    if (on('b1') && b1Shape(labels)) return true;
    if (on('b6') &&
        holds('b6:nsdd', x.nsdd) &&
        next == 0x2D &&
        end + 1 < text.length &&
        holds(
          'b6:letterDigit',
          c.letters.contains(cpAt(text, end + 1)) ||
              c.digits.contains(cpAt(text, end + 1)),
        )) {
      return true;
    }
    if (on('b7') &&
        next != null &&
        c.word.contains(next) &&
        holds('b7:hostOnly', hostOnly(text, link)) &&
        holds('b7:spaced', !unspaced(next))) {
      return true;
    }
    if (on('b14') &&
        _ipv4.hasMatch(host) &&
        next == 0x2E &&
        end + 1 < text.length &&
        holds('b14:digit', _asciiDigit(text.codeUnitAt(end + 1)))) {
      return true;
    }
    if (on('b15') &&
        next == 0x2E &&
        end + 1 < text.length &&
        hostOnly(text, link)) {
      final glue = cpAt(text, end + 1);
      if (c.letters.contains(glue) &&
          !c.macLetters.contains(glue) &&
          !unspaced(glue)) {
        return true;
      }
    }
    if (on('question 2') &&
        holds('q2:quad', _ipv4.hasMatch(host)) &&
        host.split('.').any((o) => o.length >= 2 && o.startsWith('0'))) {
      return true;
    }
    return false;
  }

  /// a2: whether a Cf run that a letter, mark or digit outside the unspaced
  /// scripts precedes ends right before [start].
  bool cfRunInWord(String text, int start) {
    var i = start;
    while (i > 0 && c.format.contains(cpBefore(text, i))) {
      i -= width(cpBefore(text, i));
    }
    if (!holds('a2:cf', i < start) || i == 0) return false;
    final cp = cpBefore(text, i);
    return holds(
      'a2:spaced',
      (c.letters.contains(cp) ||
              c.marks.contains(cp) ||
              c.digits.contains(cp)) &&
          !unspaced(cp),
    );
  }

  /// b8: whether [l] is the any-scheme link at a `webcal://` NSDataDetector
  /// reads as `webcal:/` alone, whose host holds a decimal digit outside
  /// ASCII and the fullwidth forms.
  bool webcalWithoutHost(String text, ProbeReading r, Link l) {
    if (!text.substring(l.start, l.end).toLowerCase().startsWith('webcal://')) {
      return false;
    }
    if (!r.candidates!.any(
      (x) =>
          x.nsdd &&
          x.link.start == l.start &&
          text.substring(x.link.start, x.link.end).toLowerCase() == 'webcal:/',
    )) {
      return false;
    }
    final host = authorityOf(text.substring(l.start + 9, l.end));
    return holds(
      'b8:digits',
      host.runes.any(
        (cp) =>
            c.digits.contains(cp) &&
            cp >= 0x80 &&
            !(cp >= 0xFF10 && cp <= 0xFF19),
      ),
    );
  }

  /// [link] after the cuts, in the ledger's order until none changes it,
  /// each adding its region to [regions], or a3's to [cutOffs]; null where
  /// a cut leaves no link. An email or phone takes a3's cut alone, as darwin
  /// reads it with the text from the cut to its end as spaces.
  Link? cut(
    String text,
    Link link,
    List<_Region> regions,
    List<_CutOff> cutOffs, {
    required bool stage7,
    Map<Link, ({int at, Link? kept})>? addresses,
  }) {
    if (link.kind != 'web') {
      final int at;
      final Link? kept;
      if (addresses != null) {
        final found = addresses[link];
        if (found == null) return link;
        at = found.at;
        kept = found.kept;
      } else {
        final cutAt = on('a3') ? a3Cut(text, link) : null;
        if (cutAt == null) return link;
        at = cutAt;
        final r = reading(
          '${text.substring(0, at)}${' ' * (link.end - at)}'
          '${text.substring(link.end)}',
        );
        if (r == null) return null;
        kept = longestFrom(r, link, at);
      }
      cutOffs.add((whole: link, link: kept, from: at, stage7: stage7));
      return kept;
    }
    ({Link whole, int from})? a3;
    Link? done(Link? result) {
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
      final (edit, at) = cutAt(text, l);
      if (edit == null) return done(l);
      final end = stage7
          ? trimAnyScheme(text, l.start, at!)
          : webEnd(text, l.start, at!);
      if (edit == 'a3') {
        a3 = (whole: l, from: end);
      } else {
        regions.add((start: l.start, from: end, to: l.end));
      }
      if (end <= l.start ||
          _schemeAlone.hasMatch(text.substring(l.start, end))) {
        return done(null);
      }
      l = Link(
        l.start,
        end,
        'web',
        stage7
            ? sanitizeUrl(text.substring(l.start, end))
            : urlOf(text, l, end),
      );
    }
  }

  /// The candidate of [r] of [link]'s kind that starts where it does and ends
  /// by [at], the longest.
  Link? longestFrom(ProbeReading r, Link link, int at) {
    Link? kept;
    for (final x in r.candidates!) {
      if (x.link.kind == link.kind &&
          x.link.start == link.start &&
          x.link.end <= at &&
          (kept == null || x.link.end > kept.end)) {
        kept = x.link;
      }
    }
    return kept;
  }

  /// p3: each email or phone of [cands] that a3 cuts, where and what it
  /// keeps, read from one stand-in per segment with each such link's cut-off
  /// text as spaces; null where a reading is missing.
  Map<Link, ({int at, Link? kept})>? cutAddresses(
    String text,
    List<_Cand> cands,
    Segments segments,
    _Windows? windows,
  ) {
    final cut = <(Link, int)>[];
    if (on('a3')) {
      for (final x in cands) {
        if (x.link.kind == 'web') continue;
        final at = a3Cut(text, x.link);
        if (at != null) cut.add((x.link, at));
      }
    }
    final out = <Link, ({int at, Link? kept})>{};
    for (final group in segments.group(cut, (c) => c.$1.start)) {
      final window = windowOf(
        text,
        group,
        (c) => c.$1.start,
        segments,
        windows,
      );
      final from = window?.from ?? 0;
      final units = text
          .substring(from, window?.to ?? text.length)
          .codeUnits
          .toList();
      for (final (link, at) in group) {
        units.fillRange(at - from, link.end - from, 0x20);
      }
      final r = reading(String.fromCharCodes(units));
      if (r == null) return null;
      for (final (link, at) in group) {
        final kept = longestFrom(r, _shifted(link, -from), at - from);
        out[link] = (at: at, kept: kept == null ? null : _shifted(kept, from));
      }
    }
    return out;
  }

  /// The first cut of the ledger that ends [l] before its end, and where.
  (String?, int?) cutAt(String text, Link l) {
    for (final (edit, find) in <(String, int? Function(String, Link))>[
      ('a1', a1Cut),
      ('a3', a3Cut),
      ('b3', b3Cut),
      ('b9', b9Cut),
      ('b10', b10Cut),
      ('b11', b11Cut),
      ('question 4', q4Cut),
    ]) {
      if (!on(edit)) continue;
      final at = find(text, l);
      if (at != null && at < l.end) return (edit, at);
    }
    return (null, null);
  }

  /// a1: a scheme link's host end, where a run of `. , ; ! '` and then a '?'
  /// or ':' follow it.
  int? a1Cut(String text, Link l) {
    final host = hostStart(text, l);
    final h = host ?? (holds('a1:scheme', false) ? l.start : null);
    if (h == null || h >= l.end || text[h] == '[') return null;
    var q = h;
    while (q < l.end && !'/?#:'.contains(text[q])) {
      q++;
    }
    if (q >= l.end || !'?:'.contains(text[q])) return null;
    var r = q;
    while (r > h && ".,;!'".contains(text[r - 1])) {
      r--;
    }
    return r < q ? r : null;
  }

  /// a3: the first invisible space of [l]: one of [invisibleSpaces] other
  /// than a ZWNJ or ZWJ between letters, marks, digits or symbols, or one of
  /// [domainInvisibleSpaces] in its [addressDomain].
  int? a3Cut(String text, Link l) {
    final domain = addressDomain(text.substring(l.start, l.end), l.kind);
    for (var i = l.start; i < l.end;) {
      final cp = cpAt(text, i);
      if (invisibleSpaces.contains(cp)) {
        final joiner =
            (cp == 0x200C || cp == 0x200D) &&
            i > 0 &&
            i + 1 < text.length &&
            joins(cpBefore(text, i)) &&
            joins(cpAt(text, i + 1));
        if (holds('a3:joiner', !joiner)) return i;
      } else if (domain != null &&
          domainInvisibleSpaces.contains(cp) &&
          holds(
            'a3:domain',
            domain.$1 <= i - l.start && i - l.start < domain.$2,
          )) {
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
  (int, int)? addressDomain(String slice, String kind) {
    if (_mailtoSlashes.matchAsPrefix(slice) case final scheme?) {
      final authority = authorityOf(slice.substring(scheme.end));
      final start = scheme.end + authority.lastIndexOf('@') + 1;
      return (start, start + hostOf(slice.substring(start)).length);
    }
    if (kind != 'email' ||
        !holds('a3:mailto', !_writtenMailto.hasMatch(slice))) {
      return null;
    }
    return (slice.lastIndexOf('@') + 1, slice.length);
  }

  /// a3: whether [link] is a scheme and at most two '/', where the text
  /// after its ':' is at most two '/' and then an invisible space.
  bool schemeAloneBeforeInvisible(String text, Link link) {
    final slice = text.substring(link.start, link.end);
    if (!_schemeAlone.hasMatch(slice)) return false;
    var q = link.start + slice.indexOf(':') + 1;
    for (var n = 0; n < 2 && q < text.length && text[q] == '/'; n++) {
      q++;
    }
    return q < text.length &&
        holds('a3:follows', invisibleSpaces.contains(cpAt(text, q)));
  }

  bool joins(int cp) =>
      c.letters.contains(cp) ||
      c.marks.contains(cp) ||
      c.digits.contains(cp) ||
      c.symbols.contains(cp);

  /// b3: the first ')' of [l] that it does not open and that only
  /// `. , ; ! ' ( ) ? :` follow to its end.
  int? b3Cut(String text, Link l) {
    var open = 0;
    for (var i = l.start; i < l.end; i++) {
      final ch = text[i];
      if (ch == ')') {
        var tail = true;
        for (var j = i + 1; j < l.end; j++) {
          if (!".,;!'()?:".contains(text[j])) {
            tail = false;
            break;
          }
        }
        if (tail && open <= 0) return i;
        open--;
      } else if (ch == '(') {
        open++;
      }
    }
    return null;
  }

  /// b9: before an unspaced-script character of a scheme link's host that
  /// follows another character of its label.
  int? b9Cut(String text, Link l) {
    final h = hostStart(text, l);
    if (h == null || h >= l.end || text[h] == '[') return null;
    for (var i = h; i < l.end;) {
      final cp = cpAt(text, i);
      if ('/?#:'.codeUnits.contains(cp)) return null;
      if (i > h &&
          unspaced(cp) &&
          !unspaced(cpBefore(text, i)) &&
          holds('b9:label', text[i - 1] != '.')) {
        return i;
      }
      i += width(cp);
    }
    return null;
  }

  /// b10: where a non-word character follows [l], before the first
  /// character of its trailing non-word run that is neither ASCII nor Cf.
  int? b10Cut(String text, Link l) {
    final follows = l.end < text.length && !c.word.contains(cpAt(text, l.end));
    if (!holds('b10:follow', follows)) return null;
    int? at;
    for (var i = l.end; i > l.start;) {
      final cp = cpBefore(text, i);
      if (c.word.contains(cp)) break;
      i -= width(cp);
      if (cp >= 0x80 && holds('b10:cf', !c.format.contains(cp))) at = i;
    }
    return at;
  }

  /// b11: before [l]'s trailing run of ” ’ ….
  int? b11Cut(String text, Link l) {
    var e = l.end;
    while (e > l.start && '”’…'.contains(text[e - 1])) {
      e--;
    }
    return e < l.end ? e : null;
  }

  /// Question 4b: whether [link] is NSDataDetector's reading of a scheme
  /// and one '/' of a `scheme://` whose authority starts outside the grammar.
  bool schemeSlashOutsideGrammar(String text, Link link) {
    final end = link.end;
    if (!_schemeSlash.hasMatch(text.substring(link.start, end)) ||
        !text.startsWith('/', end) ||
        end + 1 >= text.length) {
      return false;
    }
    final cp = cpAt(text, end + 1);
    return !'/?#['.codeUnits.contains(cp) && !hostChar(text, end + 1);
  }

  /// Whether the character at [i] of [text] is one question 4's host grammar
  /// takes: a letter, mark, digit, Cf, '-', '_', '.' or a '%XX'.
  bool hostChar(String text, int i) {
    final cp = cpAt(text, i);
    if (cp == 0x25) return _percent.matchAsPrefix(text, i) != null;
    return c.letters.contains(cp) ||
        c.marks.contains(cp) ||
        c.digits.contains(cp) ||
        c.format.contains(cp) ||
        '-_.'.codeUnits.contains(cp);
  }

  /// Question 4: at the first character of a scheme link's host, after any
  /// userinfo and outside an IP literal, that is no letter, mark, digit, Cf,
  /// '-', '_', '.' or '%XX', before its port, path, query or fragment.
  int? q4Cut(String text, Link l) {
    final h = hostStart(text, l);
    if (h == null || h >= l.end) return null;
    if (!holds('q4:literal', text[h] != '[')) return null;
    for (var i = h; i < l.end;) {
      final cp = cpAt(text, i);
      if ('/?#:'.codeUnits.contains(cp)) return null;
      if (!hostChar(text, i)) return i;
      i += cp == 0x25 ? 3 : width(cp);
    }
    return null;
  }

  /// Where the host of [l], a link written with a scheme and `://`, starts:
  /// after the `://` and any userinfo; null for a link without one.
  int? hostStart(String text, Link l) {
    final slice = text.substring(l.start, l.end);
    final scheme = _scheme.firstMatch(slice);
    if (scheme == null) return null;
    final authority = authorityOf(slice.substring(scheme.end));
    return l.start + scheme.end + authority.lastIndexOf('@') + 1;
  }

  /// Whether [label] holds a letter outside ASCII and the unspaced scripts.
  bool spacedLetter(String label) => label.runes.any(
    (cp) => cp >= 0x80 && !unspaced(cp) && c.letters.contains(cp),
  );

  /// Whether [labels] end in an unspaced-script TLD with an ASCII label
  /// before it.
  bool b1Shape(List<String> labels) =>
      labels.length >= 2 &&
      labels.last.isNotEmpty &&
      labels.last.runes.every(unspaced) &&
      holds(
        'b1:ascii',
        labels[labels.length - 2].isNotEmpty &&
            labels[labels.length - 2].codeUnits.every((u) => u < 0x80),
      );

  /// The domain of [address], an email's text: after the '@' that ends its
  /// local part, up to a ':', without the [domainInvisibleSpaces] its
  /// ToASCII form leaves out; null where no '@' ends one. After a written
  /// `mailto:`, the local part is in the first '/'-separated part of the
  /// text before any '?', and after `mailto://` any '#', that holds an '@',
  /// and ends at its last '@'; a bare address's ends at its last '@'.
  String? emailDomain(String address) {
    final mailbox = switch (_mailto.matchAsPrefix(address)) {
      final scheme? =>
        address
            .substring(scheme.end)
            .split(_writtenMailto.hasMatch(address) ? '?' : RegExp('[?#]'))
            .first
            .split('/')
            .where((part) => part.contains('@'))
            .firstOrNull,
      null => address,
    };
    if (mailbox == null || !mailbox.contains('@')) return null;
    final domain = mailbox.substring(mailbox.lastIndexOf('@') + 1);
    return String.fromCharCodes(
      domain
          .split(':')
          .first
          .runes
          .where(
            (cp) => holds('b16:toAscii', !domainInvisibleSpaces.contains(cp)),
          ),
    );
  }

  /// Whether [domain] is an IPv4 address or ends in a listed TLD in any case.
  bool onListedTld(String domain) =>
      _ipv4.hasMatch(domain) ||
      d.tlds.contains(domain.split('.').last.toLowerCase());
}

/// The invisible spaces a link ends before: the characters a darwin link
/// holds and `_sanitizeUrl` leaves out of its URL, and U+1680.
final invisibleSpaces = CodePoints.of([
  (0x1680, 0x1680),
  (0x200B, 0x200D),
  (0x2060, 0x2065),
  (0x206A, 0x206F),
  (0xFEFF, 0xFEFF),
]);

/// The invisible spaces an address ends before in its domain beside
/// [invisibleSpaces]: the Default_Ignorable code points that NSDataDetector's
/// URL, the domain's ToASCII form, leaves out of the domain of an address
/// that no `mailto:` without `//` starts. An address with no written scheme
/// holds only the Hangul fillers among them.
final domainInvisibleSpaces = CodePoints.of([
  (0x00AD, 0x00AD),
  (0x034F, 0x034F),
  (0x115F, 0x1160),
  (0x17B4, 0x17B5),
  (0x180B, 0x180D),
  (0x180F, 0x180F),
  (0x3164, 0x3164),
  (0xFE00, 0xFE0F),
  (0xFFA0, 0xFFA0),
  (0xE0100, 0xE01EF),
]);

/// Whether [link] of [text] is a web link with no scheme: its URL is
/// `http://` and its text.
bool bare(String text, Link link) =>
    link.kind == 'web' &&
    link.url == 'http://${text.substring(link.start, link.end)}';

/// Whether [link] of [text] has no port, path, query or fragment.
bool hostOnly(String text, Link link) =>
    !text.substring(link.start, link.end).contains(RegExp('[:/?#]'));

/// [slice] up to its first ':', '/', '?' or '#'.
String hostOf(String slice) {
  final end = slice.indexOf(RegExp('[:/?#]'));
  return end < 0 ? slice : slice.substring(0, end);
}

/// [rest] up to its first '/', '?' or '#'.
String authorityOf(String rest) {
  final end = rest.indexOf(RegExp('[/?#]'));
  return end < 0 ? rest : rest.substring(0, end);
}

/// The URL R0 stage 5 gives [link] of [text] ended at [end]: its text where
/// [link]'s URL is its text, else `http://` and its text.
String urlOf(String text, Link link, int end) {
  final slice = text.substring(link.start, end);
  return bare(text, link) ? 'http://$slice' : slice;
}

/// [s] with each fullwidth digit as its ASCII digit.
String foldWidth(String s) => String.fromCharCodes(
  s.codeUnits.map((u) => _fullwidthDigit(u) ? u - 0xFF10 + 0x30 : u),
);

bool _fullwidthDigit(int u) => u >= 0xFF10 && u <= 0xFF19;

bool _asciiDigit(int u) => u >= 0x30 && u <= 0x39;

final _scheme = RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*://');
final _schemeAlone = RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*:/{0,2}$');
final _writtenMailto = RegExp('^mailto:(?!//)', caseSensitive: false);
final _mailto = RegExp('mailto:', caseSensitive: false);
final _mailtoSlashes = RegExp('mailto://', caseSensitive: false);
final _schemeSlash = RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*:/$');
final _percent = RegExp('%[0-9A-Fa-f]{2}');
final _ipv4 = RegExp(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$');
final _emailAddress = RegExp(
  r'([a-zA-Z0-9+._%\-]{1,256})@([a-zA-Z0-9][a-zA-Z0-9\-]{0,64}(?:\.[a-zA-Z0-9][a-zA-Z0-9\-]{0,25})+)',
);

/// The unspaced scripts: Han, kana, Bopomofo, Hangul, Thai, Lao, Khmer and
/// Myanmar, with CJK symbols and punctuation, by block.
bool unspaced(int cp) =>
    (cp >= 0x0E00 && cp <= 0x0EFF) ||
    (cp >= 0x1000 && cp <= 0x109F) ||
    (cp >= 0x1100 && cp <= 0x11FF) ||
    (cp >= 0x1780 && cp <= 0x17FF) ||
    (cp >= 0x2E80 && cp <= 0x9FFF) ||
    (cp >= 0xA960 && cp <= 0xA97F) ||
    (cp >= 0xAC00 && cp <= 0xD7FF) ||
    (cp >= 0xF900 && cp <= 0xFAFF) ||
    (cp >= 0xFF66 && cp <= 0xFFDC) ||
    (cp >= 0x20000 && cp <= 0x3FFFF);

/// The code point that starts at [i] of [text].
int cpAt(String text, int i) {
  final high = text.codeUnitAt(i);
  if (high >= 0xD800 && high <= 0xDBFF && i + 1 < text.length) {
    final low = text.codeUnitAt(i + 1);
    if (low >= 0xDC00 && low <= 0xDFFF) {
      return 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00);
    }
  }
  return high;
}

/// The code point that ends before [i] of [text].
int cpBefore(String text, int i) {
  final low = text.codeUnitAt(i - 1);
  if (i >= 2 && low >= 0xDC00 && low <= 0xDFFF) {
    final high = text.codeUnitAt(i - 2);
    if (high >= 0xD800 && high <= 0xDBFF) {
      return 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00);
    }
  }
  return low;
}

/// [cp]'s UTF-16 length.
int width(int cp) => cp > 0xFFFF ? 2 : 1;

/// Whether the UTF-16 unit [c] ends a token: tab, LF, FF, CR or space.
bool endsToken(int c) =>
    c == 0x09 || c == 0x0A || c == 0x0C || c == 0x0D || c == 0x20;

/// p1: the units of [text] it reads, all of them up to [inputBound], else
/// up to its last tab, LF, FF, CR or space at or before its [inputBound]th
/// unit that no phone of NSDataDetector's results [raw] spans.
int boundOf(String text, List<RawResult> raw) {
  if (text.length <= inputBound) return text.length;
  for (var w = inputBound - 1; w >= 0; w--) {
    if (endsToken(text.codeUnitAt(w)) &&
        !raw.any((r) => r.phone && r.start < w && w < r.end)) {
      return w;
    }
  }
  return 0;
}

/// The segments of a text: its tokens, runs of units other than tab, LF,
/// FF, CR and space, each run of tokens that one of NSDataDetector's phones
/// joins taken as one.
class Segments {
  /// The segments of [text], whose NSDataDetector results are [raw].
  Segments(String text, List<RawResult> raw) {
    final joined = List.filled(text.length, false);
    for (final r in raw) {
      if (r.phone) joined.fillRange(r.start, r.end, true);
    }
    bool inside(int i) => joined[i] || !endsToken(text.codeUnitAt(i));
    for (var i = 0; i < text.length; i++) {
      if (inside(i) && (i == 0 || !inside(i - 1))) _starts.add(i);
      if (inside(i) && (i + 1 == text.length || !inside(i + 1))) {
        _ends.add(i + 1);
      }
    }
  }

  final _starts = <int>[];
  final _ends = <int>[];

  /// The segments as [start, end) spans, in order.
  List<(int, int)> get spans => [
    for (var k = 0; k < _starts.length; k++) (_starts[k], _ends[k]),
  ];

  /// The span of the segment that holds the offset [i], or of the last one
  /// before it; null before the first.
  (int, int)? spanOf(int i) {
    final start = startOf(i);
    if (start == null) return null;
    return (start, _ends[_starts.indexOf(start)]);
  }

  /// The start of the segment that holds the offset [i], or of the last one
  /// before it; null before the first.
  int? startOf(int i) {
    var lo = 0;
    var hi = _starts.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_starts[mid] <= i) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo == 0 ? null : _starts[lo - 1];
  }

  /// [items] in their order, grouped by the segment [at] places each in.
  List<List<T>> group<T>(List<T> items, int Function(T) at) {
    final groups = <int?, List<T>>{};
    for (final item in items) {
      (groups[startOf(at(item))] ??= []).add(item);
    }
    return groups.values.toList();
  }
}

/// p4's segment windows of a text, from the unit before a segment to three
/// after it, and the native links stage 3 keeps of the text's reading, which
/// a window's stand-in's cap counts in the segments before its own.
class _Windows {
  _Windows(this.text, List<Link> kept)
    : _kept = [for (final l in kept) l.start]..sort();

  final String text;
  final List<int> _kept;

  /// The window of the segment [span], as offsets in the text.
  (int, int) of((int, int) span) => (
    span.$1 == 0 ? 0 : span.$1 - 1,
    span.$2 + 3 > text.length ? text.length : span.$2 + 3,
  );

  /// The native links stage 3 keeps before [start].
  int before(int start) => _kept.where((k) => k < start).length;

  /// The native links stage 3 keeps in the segment [span].
  int keptIn((int, int) span) =>
      _kept.where((k) => span.$1 <= k && k < span.$2).length;
}

Link _shifted(Link l, int by) => Link(l.start + by, l.end + by, l.kind, l.url);

bool _sameResults(List<RawResult> a, List<RawResult> b) =>
    a.length == b.length &&
    [
      for (var i = 0; i < a.length; i++)
        a[i].start == b[i].start &&
            a[i].end == b[i].end &&
            a[i].value == b[i].value,
    ].every((same) => same);

/// Each of [texts]' prediction under [variant], reading every text a
/// prediction needs through [read] until none is missing.
Future<List<Prediction>> predictAll(
  Predictor predictor,
  List<String> texts,
  Variant variant,
  Future<List<ProbeReading>> Function(List<String> texts) read,
) async {
  final out = List<Prediction?>.filled(texts.length, null);
  while (true) {
    predictor.missing.clear();
    for (var i = 0; i < texts.length; i++) {
      out[i] ??= predictor.predict(texts[i], variant);
    }
    if (predictor.missing.isEmpty) break;
    final missing = predictor.missing.toList();
    final readings = await read(missing);
    for (var i = 0; i < missing.length; i++) {
      predictor.readings[missing[i]] = readings[i];
    }
  }
  return [for (final p in out) p!];
}
