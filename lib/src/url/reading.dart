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

/// The links of [text]: darwin's stages over the stage-2 state [read]
/// gives, ux's departures from darwin's reading each an edit of that state
/// at the stage it changes.
List<UrlMatch> readLinks(String text, Stage2Reader read) {
  if (text.isEmpty || !hasSigil(text)) return const [];
  final run = _Run(read);
  final state = run.edited(text);
  return run.stages(text, [for (final x in state.cands) x.link], state.any);
}

/// Text a cut other than an invisible space's removes from a link, read as
/// text after a link's end.
typedef _Region = ({int start, int from, int to});

/// Text an invisible space cuts off [whole], the link as that cut finds it,
/// at stage 2 or, where [stage7], stage 7; [link] is what the cuts leave of
/// it.
typedef _CutOff = ({UrlMatch whole, UrlMatch? link, int from, bool stage7});

typedef _State = ({List<Candidate> cands, List<UrlMatch> any});

class _Run {
  _Run(this._read);

  final Stage2Reader _read;
  final _readings = <String, Stage2>{};

  Stage2 reading(String text) => _readings[text] ??= _read(text);

  List<UrlMatch> darwinOf(String text) {
    if (text.isEmpty || !hasSigil(text)) return const [];
    return finish(
      text,
      stage3(text, [for (final c in reading(text).candidates) c.link]).kept,
      anySchemeLinks(text),
    );
  }

  /// darwin's stages 3 to 7 over the candidates [cands] and the any-scheme
  /// links [any] of [text], the continuation cut skipping a candidate of
  /// every kind and an any-scheme link.
  List<UrlMatch> stages(String text, List<UrlMatch> cands, List<UrlMatch> any) {
    final st3 = stage3(text, cands, everyKind: true);
    return finish(text, st3.kept, [
      for (final l in any)
        if (!st3.cuts.any((cut) => continuesPath(text, cut, l.start, l.end))) l,
    ]);
  }

  /// The edited stage-2 candidates and stage-7 any-scheme links of [text].
  _State edited(String text) {
    final r = reading(text);
    final tel = telLinks(text);
    var cands = [
      for (final x in r.candidates)
        if (!tel.any(
          (t) =>
              t.link.start <= x.link.start &&
              x.link.end <= t.link.end &&
              x.link.kind == UrlMatchKind.phone,
        ))
          x,
      ...added(text),
      ...tel,
    ];
    cands = [
      for (final x in cands) (link: rewrite(text, r, x.link), nsdd: x.nsdd),
    ];
    cands = [
      for (final x in cands)
        if (!dropped(text, x)) x,
    ];
    final regions = <_Region>[];
    final cutOffs = <_CutOff>[];
    cands = [
      for (final x in cands)
        if (cut(text, x.link, regions, cutOffs, stage7: false) case final link?)
          (link: link, nsdd: x.nsdd),
    ];
    final any = [
      for (final l in anySchemeLinks(text))
        if (!webcalWithoutHost(text, r, l))
          ?cut(text, l, regions, cutOffs, stage7: true),
    ];
    return remainders(text, cands, any, regions, cutOffs);
  }

  /// [cands] and [any] with each region's text read as after a link's end,
  /// and the text an invisible space cuts off each link the reading keeps
  /// whole starting no link.
  _State remainders(
    String text,
    List<Candidate> cands,
    List<UrlMatch> any,
    List<_Region> regions,
    List<_CutOff> cutOffs,
  ) {
    final read = <_Region>[];
    for (final region in regions) {
      if (region.from <= region.start) continue;
      if (read.any((r) => r.from <= region.from && region.from < r.to)) {
        continue;
      }
      read.add(region);
      final blanked =
          '${text.substring(0, region.start)}'
          '${' ' * (region.from - region.start)}'
          '${text.substring(region.from)}';
      final sub = edited(blanked);
      bool inside(int start) => region.from <= start && start < region.to;
      cands = [
        for (final x in cands)
          if (!inside(x.link.start)) x,
        for (final x in sub.cands)
          if (inside(x.link.start)) x,
      ];
      any = [
        for (final l in any)
          if (!inside(l.start)) l,
        for (final l in sub.any)
          if (inside(l.start)) l,
      ];
    }
    bool replaced(int start) =>
        read.any((r) => r.from <= start && start < r.to);
    final live = [
      for (final o in cutOffs)
        if (!replaced(o.whole.start)) o,
    ];
    if (live.isEmpty) return (cands: cands, any: any);
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
        if (whole.any((l) => l.start == o.whole.start && l.end == o.whole.end))
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

  List<Candidate> added(String text) => [
    ...emailAddress(text),
    for (final link in idnLinks(text)) (link: link, nsdd: false),
    ...glueLinks(text),
    ...afterCfRuns(text),
  ];

  /// Each Patterns.EMAIL_ADDRESS match whose domain is an IPv4 address or
  /// ends in a listed TLD, as an email.
  List<Candidate> emailAddress(String text) => [
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
  /// scripts as 'q' and each such digit as '0', and in that text with each
  /// listed TLD after a run's first label as written where NSDataDetector's
  /// bare-host set holds it, else that set's ASCII TLD of its length.
  List<UrlMatch> idnLinks(String text) {
    final runs = labelRuns(text);
    if (runs.isEmpty) return const [];
    final main = StringBuffer();
    var at = 0;
    var changed = false;
    final replaced = <int>{};
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
      int? hostEnd,
    ) {
      for (final l in reading) {
        if (l.kind != UrlMatchKind.web ||
            l.url != 'http://${s.substring(l.start, l.end)}') {
          continue;
        }
        final sliceEnd = _hostOf(s.substring(l.start, l.end)).length + l.start;
        if (hostEnd != null && sliceEnd != hostEnd) continue;
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

    if (changed) take(standIn, darwinOf(standIn), null, null);
    for (final (start, end) in runs) {
      var labelStart = start;
      var first = true;
      for (var i = start; i <= end; i++) {
        if (i < end && text.codeUnitAt(i) != 0x2E) continue;
        final label = text.substring(labelStart, i);
        if (!first && isTld(label)) {
          final held = nsddBareTlds.contains(label.toLowerCase());
          final replacedLetter = replaced.any((r) => labelStart <= r && r < i);
          if (!held || replacedLetter) {
            final tld = held ? label : _asciiTldOf(label.length);
            final s =
                '${standIn.substring(0, labelStart)}$tld'
                '${standIn.substring(i)}';
            final delta = tld.length - label.length;
            final tldEnd = labelStart + tld.length;
            take(
              s,
              darwinOf(s),
              (q) => q <= labelStart
                  ? q
                  : q >= tldEnd
                  ? q - delta
                  : null,
              tldEnd,
            );
          }
        }
        first = false;
        labelStart = i + 1;
      }
    }
    return out;
  }

  /// The IDN stand-in's runs of [text]: letters, marks and digits with '-',
  /// '_' and '.', from a letter or digit to the last letter, mark or digit,
  /// that hold a non-ASCII character.
  List<(int, int)> labelRuns(String text) {
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
      if (last > start &&
          text.substring(start, last).codeUnits.any((u) => u >= 0x80)) {
        runs.add((start, last));
      }
      i = end;
    }
    return runs;
  }

  /// At each `tel:` in any case, the web link darwin reads there with `tel`
  /// as `sms`, its URL its text.
  List<Candidate> telLinks(String text) {
    final out = <Candidate>[];
    final lower = text.toLowerCase();
    for (
      var at = lower.indexOf('tel:');
      at >= 0;
      at = lower.indexOf('tel:', at + 1)
    ) {
      final s =
          '${text.substring(0, at)}'
          '${String.fromCharCodes([for (var i = 0; i < 3; i++) _sms(text.codeUnitAt(at + i), i)])}'
          '${text.substring(at + 3)}';
      for (final l in darwinOf(s)) {
        if (l.start == at && l.kind == UrlMatchKind.web) {
          out.add((
            link: UrlMatch(
              start: l.start,
              end: l.end,
              url: text.substring(l.start, l.end),
              kind: UrlMatchKind.web,
            ),
            nsdd: false,
          ));
        }
      }
    }
    return out;
  }

  static int _sms(int unit, int i) =>
      'sms'.codeUnitAt(i) - (unit < 0x61 ? 0x20 : 0);

  /// The host-only candidate darwin reads with the character after a host's
  /// '.' as spaces, where letterCharacterSet holds that character and
  /// general category L does not.
  List<Candidate> glueLinks(String text) {
    final out = <Candidate>[];
    for (var at = text.indexOf('.'); at >= 0; at = text.indexOf('.', at + 1)) {
      if (at + 1 >= text.length) break;
      final cp = cpAt(text, at + 1);
      if (!isMark(cp) || isLetter(cp) || isUnspaced(cp)) continue;
      final s =
          '${text.substring(0, at + 1)}${' ' * width(cp)}'
          '${text.substring(at + 1 + width(cp))}';
      for (final x in reading(s).candidates) {
        if (x.link.end == at && _bare(s, x.link) && _hostOnly(s, x.link)) {
          out.add((link: x.link, nsdd: false));
        }
      }
    }
    return out;
  }

  /// The candidates with no scheme darwin reads right after a Cf run that an
  /// unspaced-script character precedes, with the run as spaces.
  List<Candidate> afterCfRuns(String text) {
    final out = <Candidate>[];
    var i = 0;
    while (i < text.length) {
      final cp = cpAt(text, i);
      if (!isFormat(cp)) {
        i += width(cp);
        continue;
      }
      final start = i;
      while (i < text.length && isFormat(cpAt(text, i))) {
        i += width(cpAt(text, i));
      }
      if (start == 0 || !isUnspaced(cpBefore(text, start))) continue;
      final s =
          '${text.substring(0, start)}${' ' * (i - start)}${text.substring(i)}';
      for (final x in reading(s).candidates) {
        if (x.link.start == i && _bare(s, x.link)) {
          out.add((link: x.link, nsdd: false));
        }
      }
    }
    return out;
  }

  UrlMatch rewrite(String text, Stage2 r, UrlMatch link) {
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
    if (link.kind == UrlMatchKind.web) link = fullwidthPort(text, link);
    if (link.kind == UrlMatchKind.phone) {
      for (final raw in r.raw) {
        if (!raw.phone || raw.start != link.start || raw.end != link.end) {
          continue;
        }
        final extension = _extensionDigits(raw.value);
        if (extension == null) continue;
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
    return link;
  }

  /// [link] with its fullwidth port as ASCII digits, and a host-only link
  /// with no scheme run on over ':' and fullwidth digits that an unspaced
  /// letter follows.
  UrlMatch fullwidthPort(String text, UrlMatch link) {
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

  bool dropped(String text, Candidate x) {
    final link = x.link;
    final slice = text.substring(link.start, link.end);
    if (link.kind == UrlMatchKind.email) {
      return switch (emailDomain(slice)) {
        final domain? => !onListedTld(domain),
        null => false,
      };
    }
    if (link.kind != UrlMatchKind.web) return false;
    if (schemeAloneBeforeInvisible(text, link)) return true;
    if (x.nsdd && slice.toLowerCase() == 'webcal:/') return true;
    if (schemeSlashOutsideGrammar(text, link)) return true;
    final end = link.end;
    final isBare = _bare(text, link);
    if (text.startsWith('://', end) && isBare) return true;
    if (!isBare) return false;
    final host = _hostOf(slice);
    final labels = host.split('.');
    final next = end < text.length ? cpAt(text, end) : null;
    if (cfRunInWord(text, link.start)) return true;
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
  bool cfRunInWord(String text, int start) {
    var i = start;
    while (i > 0 && isFormat(cpBefore(text, i))) {
      i -= width(cpBefore(text, i));
    }
    if (i == start || i == 0) return false;
    return isSpacedLetterMarkDigit(cpBefore(text, i));
  }

  /// Whether [l] is the any-scheme link at a `webcal://` NSDataDetector reads
  /// as `webcal:/` alone, whose host holds a decimal digit outside ASCII and
  /// the fullwidth forms.
  bool webcalWithoutHost(String text, Stage2 r, UrlMatch l) {
    if (!text.substring(l.start, l.end).toLowerCase().startsWith('webcal://')) {
      return false;
    }
    if (!r.candidates.any(
      (x) =>
          x.nsdd &&
          x.link.start == l.start &&
          text.substring(x.link.start, x.link.end).toLowerCase() == 'webcal:/',
    )) {
      return false;
    }
    final host = _authorityOf(text.substring(l.start + 9, l.end));
    return host.runes.any(
      (cp) => isDigit(cp) && cp >= 0x80 && !(cp >= 0xFF10 && cp <= 0xFF19),
    );
  }

  /// [link] after the cuts, in their order until none changes it,
  /// each adding its region to [regions], or an invisible space's to
  /// [cutOffs]; null where a cut leaves no link. An email or phone takes the
  /// invisible space's cut alone, as darwin reads it with the text from the
  /// cut to its end as spaces.
  UrlMatch? cut(
    String text,
    UrlMatch link,
    List<_Region> regions,
    List<_CutOff> cutOffs, {
    required bool stage7,
  }) {
    if (link.kind != UrlMatchKind.web) {
      final at = invisibleCut(text, link);
      if (at == null) return link;
      final s =
          '${text.substring(0, at)}${' ' * (link.end - at)}'
          '${text.substring(link.end)}';
      UrlMatch? kept;
      for (final x in reading(s).candidates) {
        if (x.link.kind == link.kind &&
            x.link.start == link.start &&
            x.link.end <= at &&
            (kept == null || x.link.end > kept.end)) {
          kept = x.link;
        }
      }
      cutOffs.add((whole: link, link: kept, from: at, stage7: stage7));
      return kept;
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
      final (edit, at) = cutAt(text, l);
      if (edit == null) return done(l);
      final end = stage7
          ? trimAnyScheme(text, l.start, at!)
          : webEnd(text, l.start, at!);
      if (edit == _Cut.invisibleSpace) {
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
  (_Cut?, int?) cutAt(String text, UrlMatch l) {
    for (final edit in _Cut.values) {
      final at = switch (edit) {
        _Cut.hostMarks => hostMarksCut(text, l),
        _Cut.invisibleSpace => invisibleCut(text, l),
        _Cut.unopenedParen => unopenedParenCut(text, l),
        _Cut.unspacedInHost => unspacedCut(text, l),
        _Cut.trailingSymbols => trailingSymbolsCut(text, l),
        _Cut.closingQuotes => closingQuotesCut(text, l),
        _Cut.hostGrammar => hostGrammarCut(text, l),
      };
      if (at != null && at < l.end) return (edit, at);
    }
    return (null, null);
  }

  /// A scheme link's host end, where a run of `. , ; ! '` and then a '?' or
  /// ':' follow it.
  int? hostMarksCut(String text, UrlMatch l) {
    final h = hostStart(text, l);
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
  int? invisibleCut(String text, UrlMatch l) {
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
      final start = 9 + authority.lastIndexOf('@') + 1;
      return (start, start + _hostOf(slice.substring(start)).length);
    }
    if (kind != UrlMatchKind.email || _writtenMailto(slice)) return null;
    return (slice.lastIndexOf('@') + 1, slice.length);
  }

  /// Whether [link] is a scheme and at most two '/', where the text after
  /// its ':' is at most two '/' and then an invisible space.
  bool schemeAloneBeforeInvisible(String text, UrlMatch link) {
    final slice = text.substring(link.start, link.end);
    if (!_schemeAlone(slice)) return false;
    var q = link.start + slice.indexOf(':') + 1;
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
  int? unopenedParenCut(String text, UrlMatch l) {
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
  int? unspacedCut(String text, UrlMatch l) {
    final h = hostStart(text, l);
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
  int? trailingSymbolsCut(String text, UrlMatch l) {
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
  int? closingQuotesCut(String text, UrlMatch l) {
    var e = l.end;
    while (e > l.start && _isClosingQuote(text.codeUnitAt(e - 1))) {
      e--;
    }
    return e < l.end ? e : null;
  }

  /// Whether [link] is NSDataDetector's reading of a scheme and one '/' of a
  /// `scheme://` whose authority starts outside the host grammar.
  bool schemeSlashOutsideGrammar(String text, UrlMatch link) {
    final end = link.end;
    if (!_schemeSlash(text.substring(link.start, end)) ||
        !text.startsWith('/', end) ||
        end + 1 >= text.length) {
      return false;
    }
    final cp = cpAt(text, end + 1);
    return !(cp == 0x2F || cp == 0x3F || cp == 0x23 || cp == 0x5B) &&
        !hostChar(text, end + 1);
  }

  /// Whether the character at [i] of [text] is one a scheme link's host
  /// takes: a letter, mark, digit, Cf, '-', '_', '.' or a '%XX'.
  bool hostChar(String text, int i) {
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
  int? hostGrammarCut(String text, UrlMatch l) {
    final h = hostStart(text, l);
    if (h == null || h >= l.end) return null;
    if (text.codeUnitAt(h) == 0x5B) return null;
    for (var i = h; i < l.end;) {
      final cp = cpAt(text, i);
      if (_isAuthorityMark(cp)) return null;
      if (!hostChar(text, i)) return i;
      i += cp == 0x25 ? 3 : width(cp);
    }
    return null;
  }

  /// Where the host of [l], a link written with a scheme and `://`, starts:
  /// after the `://` and any userinfo; null for a link without one.
  int? hostStart(String text, UrlMatch l) {
    final slice = text.substring(l.start, l.end);
    final scheme = _schemePrefix(slice);
    if (scheme == null) return null;
    final authority = _authorityOf(slice.substring(scheme));
    return l.start + scheme + authority.lastIndexOf('@') + 1;
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
    if (mailbox == null || !mailbox.contains('@')) return null;
    final domain = mailbox.substring(mailbox.lastIndexOf('@') + 1);
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
    link.url == 'http://${text.substring(link.start, link.end)}';

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
