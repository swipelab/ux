// The Dart detector's layers over probe-stages' recorded readings: readLinks
// over darwin's own stage-2 state, the second pass and NSDataDetector's model
// beside url_detect.mm's candidates, and detectLinks with recorded
// NSDataDetector candidates of given kinds in place of its model's.
import 'package:ux/src/url/match.dart';
import 'package:ux/src/url/nsdd.dart';
import 'package:ux/src/url/nsdd_model.dart';
import 'package:ux/src/url/reading.dart';
import 'package:ux/src/url/web_pass.dart';

import 'diff.dart';
import 'selfcheck.dart';
import 'wire.dart';

/// probe-stages readings by text, recording each text a read asks for and
/// each it lacks.
class Recorded {
  /// Readings that start with [readings].
  Recorded(this.readings);

  /// probe-stages readings by text.
  final Map<String, ProbeReading> readings;

  /// The texts asked for and found.
  final Set<String> requested = {};

  /// The texts asked for and lacked since [readAll]'s last round.
  final Set<String> missing = {};

  /// The segment windows of the text [cutWindows] last cut: the text, the
  /// window's offset in it and the segment.
  final Map<String, ({String text, int from, int start, int end})> windows = {};

  var _misses = 0;

  ProbeReading? _of(String text) {
    final r = readings[text];
    if (r == null) {
      missing.add(text);
      _misses++;
    } else {
      requested.add(text);
    }
    return r;
  }

  /// darwin's stage-2 state of [text] as probe-stages recorded it.
  Stage2 stage2(String text) {
    final r = _recorded(text);
    return (
      candidates: [
        for (final c in r.candidates) (link: toMatch(c.link), nsdd: c.nsdd),
      ],
      raw: [for (final x in r.raw) toResult(x)],
    );
  }

  /// probe-stages' candidates and raw results of [text].
  ({List<Candidate> candidates, List<RawResult> raw}) _recorded(String text) {
    final r = _of(text);
    if (r == null) return (candidates: const [], raw: const []);
    return (candidates: r.candidates!, raw: r.raw);
  }

  /// Sets [windows] to the segment windows readLinks reads of [text], and
  /// gives the bounded text they are cut from, or null where a reading it
  /// needs is missing.
  String? cutWindows(String text) {
    windows.clear();
    var bounded = text;
    if (text.length > inputBound) {
      if (_of(text) == null) return null;
      bounded = text.substring(0, boundOf(text, phones(text)));
    }
    if (_of(bounded) == null) return null;
    for (final (start, end) in segmentsOf(bounded, phones(bounded))) {
      final from = start == 0 ? 0 : start - 1;
      final to = end + 3 > bounded.length ? bounded.length : end + 3;
      final window = bounded.substring(from, to);
      if (window != bounded) {
        windows[window] = (text: bounded, from: from, start: start, end: end);
      }
    }
    return bounded;
  }

  /// The texts of [texts], in order, darwin reads otherwise in a segment's
  /// window alone than in the text, reading every window reading it lacks
  /// through [read].
  Future<List<String>> nonLocal(
    List<String> texts,
    Future<List<ProbeReading>> Function(List<String> texts) read,
  ) async {
    final found = <String>{};
    var pending = texts;
    while (pending.isNotEmpty) {
      missing.clear();
      final next = <String>[];
      for (final t in pending) {
        final local = _local(cutWindows(t)!);
        if (local == null) {
          next.add(t);
        } else if (!local) {
          found.add(t);
        }
      }
      if (missing.isNotEmpty) {
        final lacked = missing.toList();
        final readings = await read(lacked);
        for (var i = 0; i < lacked.length; i++) {
          this.readings[lacked[i]] = readings[i];
        }
      }
      pending = next;
    }
    windows.clear();
    return [
      for (final t in texts)
        if (found.contains(t)) t,
    ];
  }

  /// Whether darwin reads each segment window of [bounded], which
  /// [cutWindows] gave, as it reads that segment in the text; null where a
  /// window's own reading is missing.
  bool? _local(String bounded) {
    final whole = readings[bounded]!;
    for (final MapEntry(key: window, value: (:from, :start, :end, text: _))
        in windows.entries) {
      final own = _of(window);
      if (own == null) return null;
      bool inside(int i) => start <= i && i < end;
      final mine = [
        for (final c in own.candidates!)
          if (inside(c.link.start + from)) _shifted(c.link, from),
      ];
      final theirs = [
        for (final c in whole.candidates!)
          if (inside(c.link.start)) c.link,
      ];
      if (!sameLinks(mine, theirs)) return false;
    }
    return true;
  }

  /// NSDataDetector's phones of [text] as probe-stages recorded them.
  List<NsddResult> phones(String text) => [
    for (final x in _of(text)?.raw ?? const <RawResult>[])
      if (x.phone) toResult(x),
  ];

  /// The Dart detector's stage-2 state of [text] with probe-stages' recorded
  /// NSDataDetector candidates of [kinds] in place of its model's: a
  /// recorded candidate drops each of the model's it overlaps, and recorded
  /// phones join the model's results.
  Stage2 assisted(String text, Set<UrlMatchKind> kinds) {
    final raw = nsddResults(text);
    final r = _recorded(text);
    final recorded = [
      for (final c in r.candidates)
        if (c.nsdd && kinds.contains(toMatch(c.link).kind))
          (link: toMatch(c.link), nsdd: true),
    ];
    bool overlapped(UrlMatch m) =>
        recorded.any((x) => x.link.start < m.end && m.start < x.link.end);
    final nsdd = [
      for (final link in nsddCandidates(text, raw))
        if (!kinds.contains(link.kind) && !overlapped(link))
          (link: link, nsdd: true),
      ...recorded,
    ]..sort((a, b) => a.link.start.compareTo(b.link.start));
    return (
      candidates: [
        ...nsdd,
        for (final link in webPass(text)) (link: link, nsdd: false),
      ],
      raw: [
        ...raw,
        if (kinds.contains(UrlMatchKind.phone))
          for (final x in r.raw)
            if (x.phone) toResult(x),
      ],
    );
  }

  /// Each of [texts] as [reading] reads it, reading every text it lacks
  /// through [read] in rounds until none lacks one.
  Future<List<List<Link>>> readAll(
    List<String> texts,
    List<UrlMatch> Function(String text) reading,
    Future<List<ProbeReading>> Function(List<String> texts) read,
  ) async {
    final out = List<List<Link>?>.filled(texts.length, null);
    while (true) {
      missing.clear();
      for (var i = 0; i < texts.length; i++) {
        if (out[i] != null) continue;
        final before = _misses;
        final links = reading(texts[i]);
        if (_misses == before) out[i] = [for (final m in links) toLink(m)];
      }
      if (missing.isEmpty) break;
      final lacked = missing.toList();
      final found = await read(lacked);
      for (var i = 0; i < lacked.length; i++) {
        readings[lacked[i]] = found[i];
      }
    }
    return [for (final links in out) links!];
  }
}

Link _shifted(Link l, int by) => Link(l.start + by, l.end + by, l.kind, l.url);

/// [link] as the Dart detector's match.
UrlMatch toMatch(Link link) => UrlMatch(
  start: link.start,
  end: link.end,
  url: link.url,
  kind: UrlMatchKind.values.byName(link.kind),
);

/// [match] as a wire link.
Link toLink(UrlMatch match) =>
    Link(match.start, match.end, match.kind.name, match.url);

/// [raw] as the Dart detector's NSDataDetector result.
NsddResult toResult(RawResult raw) =>
    (start: raw.start, end: raw.end, phone: raw.phone, value: raw.value);

/// The texts of [texts] whose [dart] links differ from the [predicted]
/// ones.
List<String> differing(
  List<String> texts,
  List<List<Link>> dart,
  List<List<Link>> predicted,
) => [
  for (var i = 0; i < texts.length; i++)
    if (!sameLinks(dart[i], predicted[i]))
      '${printable(texts[i])}: Dart ${dart[i]}, prediction ${predicted[i]}',
];

/// The second pass's links of [text] beside url_detect.mm's second-pass
/// candidates in [r].
({List<Link> dart, List<Link> recorded}) secondPass(
  String text,
  ProbeReading r,
) => (
  dart: [for (final m in webPass(text)) toLink(m)],
  recorded: [
    for (final c in r.candidates!)
      if (!c.nsdd) c.link,
  ],
);

/// NSDataDetector's model's candidates of [text] beside url_detect.mm's
/// NSDataDetector candidates in [r], by class.
Map<LinkClass, ({List<Link> dart, List<Link> recorded})> model(
  String text,
  ProbeReading r,
) {
  final dartLinks = [
    for (final m in nsddCandidates(text, nsddResults(text))) toLink(m),
  ];
  final recordedLinks = [
    for (final c in r.candidates!)
      if (c.nsdd) c.link,
  ];
  return {
    for (final k in LinkClass.values)
      if (dartLinks.any((l) => classOf(l, text) == k) ||
          recordedLinks.any((l) => classOf(l, text) == k))
        k: (
          dart: [
            for (final l in dartLinks)
              if (classOf(l, text) == k) l,
          ],
          recorded: [
            for (final l in recordedLinks)
              if (classOf(l, text) == k) l,
          ],
        ),
  };
}
