// The darwin oracle: XUrl.match at an oracle commit over that commit's
// url_detect.mm and NSDataDetector, on macOS 26.4 (25E246).
//
//   dart run tool/url_oracle/oracle.dart catalog [--commit C] [--locale L]
//   dart run tool/url_oracle/oracle.dart diff [--oracle-only] [--kinds K,...] [--assist K,...] [--seed N] [--commit C] [--locale L]
//   dart run tool/url_oracle/oracle.dart stages [--model K,...] [--seed N | --fresh N --seed S] [--threshold P] [--locale L]
//   dart run tool/url_oracle/oracle.dart props [--commit C]
//   dart run tool/url_oracle/oracle.dart win [--commit C]
//
// It writes only under --work, a directory outside the checkout.
import 'dart:io';

import 'package:ux/src/url/match.dart';
import 'package:ux/src/url/reading.dart';

import 'corpus.dart';
import 'diff.dart';
import 'harness.dart';
import 'intree.dart';
import 'props.dart';
import 'recorded.dart';
import 'rules.dart';
import 'selfcheck.dart';
import 'win_icu.dart';
import 'wire.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) _usage();
  final options = _Options.parse(args.skip(1).toList());
  final Host host;
  try {
    host = await Host.read();
  } on StateError catch (e) {
    stderr.writeln(e.message);
    exit(1);
  }
  final commit = await host.resolve(options.commit);
  final harness = Harness(host, commit, options.work);
  final ok = switch (args.first) {
    'catalog' => await _catalog(harness, options),
    'win' => await _win(harness),
    'diff' => await _diff(harness, options),
    'stages' => await _stages(harness, options),
    'props' => await _props(harness),
    _ => _usage(),
  };
  exit(ok ? 0 : 1);
}

Future<bool> _catalog(Harness harness, _Options options) async {
  stdout.writeln(
    header(harness.host, commit: harness.commit, locale: options.locale),
  );
  final texts = await harness.catalogTexts();
  final readings = await harness.read(texts, locale: options.locale);
  final run = await harness.checkCatalog(texts, readings);
  stdout.writeln(
    'catalog: ${texts.length} texts, ${run.passed} passed, ${run.failed} failed, ${run.skipped} skipped',
  );
  for (final failure in run.failures) {
    stdout.writeln('FAILED $failure');
  }
  return run.failed == 0 && run.passed > 0;
}

Future<bool> _diff(Harness harness, _Options options) async {
  final host = harness.host;
  final locale = options.locale;
  final seed = int.parse(options.values['--seed'] ?? '3451');
  final entries = await harness.catalog();
  final catalog = {for (final e in entries) e.text}.toList();
  final tlds = readTlds(await host.show(harness.commit, 'src/tld.h'));
  final characters = await CharacterClasses.read(harness);
  final inputs = CorpusInputs(
    catalog: [...catalog]..sort(),
    inTree: await inTreeTexts(host, harness.commit),
    asciiTlds: tlds.ascii,
    idnTlds: tlds.idn,
    categories: readCategories(
      File(
        '${host.uxRoot}/tool/url_data/unicode-17.0.0/DerivedGeneralCategory.txt',
      ).readAsStringSync(),
    ),
    unicode: characters.differences.ranges,
  );
  final corpus = generateCorpus(seed, inputs);
  final encoded = encodeCorpus(corpus);
  final deterministic = encoded == encodeCorpus(generateCorpus(seed, inputs));
  File('${harness.commitDir.path}/corpus-$seed.jsonl')
      .writeAsStringSync(encoded);
  final head = header(
    host,
    commit: harness.commit,
    locale: locale,
    seed: seed,
    size: corpus.length,
  );
  stdout.writeln(head);
  final texts = [for (final c in corpus) c.text];
  final probes = await harness.read(texts, locale: locale);
  final matched = await harness.replay(texts, probes);
  final darwin = [
    for (var i = 0; i < corpus.length; i++)
      DarwinReading(corpus[i], matched[i], probes[i]),
  ];
  final json = File('${harness.commitDir.path}/darwin.json')
    ..writeAsStringSync(encodeDarwin({'header': head}, darwin));
  stdout
    ..writeln('darwin.json: ${json.path}')
    ..writeAll(counts(darwin), '\n')
    ..writeln();

  final index = {for (var i = 0; i < texts.length; i++) texts[i]: i};
  final catalogRun = await harness.checkCatalog(catalog, [
    for (final t in catalog) probes[index[t]!],
  ]);
  final rawByLocale = <String, Map<String, List<RawResult>>>{};
  for (final l in quotedLocales) {
    final quoted = {
      for (final (text, locales, _) in rawQuotes)
        if (locales.contains(l)) text,
    }.toList();
    final readings = await harness.read(quoted, locale: l);
    rawByLocale[l] = {
      for (var i = 0; i < quoted.length; i++) quoted[i]: readings[i].raw,
    };
  }
  final raw = rawMismatches(rawByLocale);
  final quotes = [for (final (_, locales, _) in rawQuotes) ...locales].length;
  stdout
    ..writeln(
      'self-check: corpus ${deterministic ? 'byte-identical' : 'differs'} '
      'across two runs of seed $seed; ${corpus.length} texts',
    )
    ..writeln(
      'self-check: catalog ${catalogRun.passed} passed, '
      '${catalogRun.failed} failed',
    )
    ..writeAll([for (final f in catalogRun.failures) 'FAILED $f'], '\n')
    ..writeln(
      'self-check: raw NSDataDetector quotes ${quotes - raw.length} of '
      '$quotes reproduced under ${quotedLocales.join(', ')}',
    )
    ..writeAll([for (final m in raw) 'RAW $m'], '\n')
    ..writeln();

  final staged = await harness.readStages(texts, locale: locale);
  final stages = stageMismatches(texts, probes, staged, matched);
  final oracleTlds = {
    for (final t in [...tlds.ascii, ...tlds.idn, ...tlds.punycode])
      t.toLowerCase(),
  };
  final nsdd = await nsddTlds(harness);
  RuleData ruleData(Set<String> newer) => RuleData(
    characters,
    tlds: oracleTlds,
    nsddBare: nsdd.bare,
    newTlds: newer,
  );
  final data = ruleData(newTlds(host.uxRoot, oracleTlds));
  Future<List<ProbeReading>> read(List<String> t) =>
      harness.readStages(t, locale: locale);
  final predictor = Predictor(data);
  for (var i = 0; i < texts.length; i++) {
    predictor.readings[texts[i]] = staged[i];
  }
  final none = await predictAll(predictor, texts, const Variant({}), read);
  final unedited = [
    for (var i = 0; i < texts.length; i++)
      if (!sameLinks(none[i].links, matched[i])) printable(texts[i]),
  ];
  final candidates = staged.fold(0, (n, r) => n + r.candidates!.length);
  final nsddCandidates = staged.fold(
    0,
    (n, r) => n + r.candidates!.where((c) => c.nsdd).length,
  );
  stdout
    ..writeln(
      'self-check 1: probe-stages read $candidates candidates, '
      '$nsddCandidates of them NSDataDetector\'s; texts whose probe-stages '
      'buffer differs from the probe\'s ${stages['buffer']!.length}, whose '
      'stage 3 differs from the buffer ${stages['stage 3']!.length}, whose '
      'stages 4-7 differ from the replay ${stages['stages 4-7']!.length}, '
      'whose prediction with no edit differs from darwin ${unedited.length}',
    )
    ..writeAll([
      for (final MapEntry(key: check, value: found) in stages.entries)
        for (final t in found) 'STAGE $check $t',
      for (final t in unedited) 'UNEDITED $t',
    ], '\n')
    ..writeln();

  final full = await predictAll(predictor, texts, Variant(allEdits), read);
  final wrong = [
    for (final e in entries)
      if (!sameLinks(full[index[e.text]!].links, e.expected))
        '${printable(e.text)}: predicted ${full[index[e.text]!].links}, '
            'expected ${e.expected}',
    for (final e in entries)
      if (!sameLinks(none[index[e.text]!].links, e.apple ?? e.expected))
        '${printable(e.text)}: with no edit ${none[index[e.text]!].links}, '
            'darwin ${e.apple ?? e.expected}',
  ];
  stdout
    ..writeln(
      'self-check 2: the prediction gives ${entries.length} catalog inputs '
      '(${entries.where((e) => e.apple != null).length} with apple:) their '
      'expected value, and with no edit their darwin reading: '
      '${wrong.length} differ',
    )
    ..writeAll([for (final w in wrong) 'CATALOG $w'], '\n')
    ..writeln();

  final idle = <String>[];
  final catalogNone = [for (final t in catalog) none[index[t]!]];
  final catalogFull = [for (final t in catalog) full[index[t]!]];
  for (final (edit, name) in ledger) {
    if (edit == 'Unicode' || edit == 'new TLDs') continue;
    if (performanceEdits.contains(edit)) {
      final without = await predictAll(
        predictor,
        catalog,
        Variant(allEdits.difference({edit})),
        read,
      );
      if (!_changes(without, catalogFull)) idle.add(name);
      continue;
    }
    final alone = await predictAll(predictor, catalog, Variant({edit}), read);
    if (!_changes(alone, catalogNone)) idle.add(name);
  }
  final unicodeTexts = [
    for (final t in texts)
      if (t.runes.any(characters.differences.contains)) t,
  ];
  final unicodeAlone = await predictAll(
    predictor,
    unicodeTexts,
    const Variant({'Unicode'}),
    read,
  );
  final unicodeChanged = [
    for (var i = 0; i < unicodeTexts.length; i++)
      if (!sameLinks(
        unicodeAlone[i].links,
        none[index[unicodeTexts[i]]!].links,
      ))
        i,
  ];
  if (unicodeChanged.isEmpty) idle.add('Unicode');
  const withheld = 'app';
  final withheldData = ruleData({withheld});
  final holding = [
    for (final t in texts)
      if (withheldData.holdsNewTld(t)) t,
  ];
  final withheldPredictor = Predictor(withheldData)
    ..readings.addAll(predictor.readings);
  final withheldReading = await predictAll(
    withheldPredictor,
    holding,
    const Variant({'new TLDs'}),
    read,
  );
  final withheldWrong = [
    for (var i = 0; i < holding.length; i++)
      if (!sameLinks(withheldReading[i].links, matched[index[holding[i]]!]))
        '${printable(holding[i])}: ${withheldReading[i].links}, darwin '
            '${matched[index[holding[i]]!]}',
  ];
  if (holding.isEmpty) idle.add('new TLDs');
  stdout
    ..writeln(
      'self-check 3: of ${ledger.length - 2} edits, '
      '${idle.where((n) => !n.startsWith('Unicode') && !n.startsWith('new TLDs')).length} '
      'change no catalog input alone, or, a class-p edit, from the whole '
      'ledger without it; '
      'the Unicode stand-in changes ${unicodeChanged.length} of '
      '${unicodeTexts.length} corpus texts holding a listed code point; with '
      '$withheld withheld as new, the new-TLD stand-in gives '
      '${holding.length - withheldWrong.length} of the ${holding.length} '
      'corpus texts holding it their darwin reading',
    )
    ..writeAll([
      for (final n in idle) 'IDLE $n',
      for (final w in withheldWrong) 'WITHHELD $w',
    ], '\n')
    ..writeln();

  final pinned = <String>[];
  final redundant = <String>[];
  final unpinned = <String>[];
  for (final conjunct in conjuncts) {
    final touched = [
      for (var i = 0; i < texts.length; i++)
        if (full[i].touched.contains(conjunct)) i,
    ];
    final relaxed = await predictAll(
      predictor,
      [for (final i in touched) texts[i]],
      Variant(allEdits, {conjunct}),
      read,
    );
    var changed = 0;
    final away = <String>[];
    for (var n = 0; n < touched.length; n++) {
      final i = touched[n];
      if (sameLinks(relaxed[n].links, full[i].links)) continue;
      changed++;
      for (final e in entries) {
        if (e.text == texts[i] && !sameLinks(relaxed[n].links, e.expected)) {
          away.add(printable(e.text));
        }
      }
    }
    if (away.isNotEmpty) {
      pinned.add('$conjunct ($changed corpus texts, pinned by ${away.first})');
    } else if (changed == 0) {
      redundant.add(conjunct);
    } else {
      unpinned.add('$conjunct ($changed corpus texts)');
    }
  }
  stdout
    ..writeln(
      'self-check 4: ${conjuncts.length} conjuncts, ${pinned.length} pinned, '
      '${redundant.length} redundant, ${unpinned.length} unpinned',
    )
    ..writeAll([
      for (final c in pinned) '  pinned $c',
      for (final c in redundant) '  redundant $c',
      for (final c in unpinned) 'UNPINNED $c',
    ], '\n')
    ..writeln();

  final representatives = representativeMismatches(data);
  stdout
    ..writeln(
      'self-check 5: ${characters.differences.length} code points of the '
      'Unicode class, ${representatives.length} whose representative\'s '
      'macOS classes differ from its Unicode 17.0.0 classes',
    )
    ..writeAll([for (final r in representatives) 'REPRESENTATIVE $r'], '\n')
    ..writeln();

  final changed = [
    for (var i = 0; i < texts.length; i++)
      if (!sameLinks(full[i].links, matched[i])) i,
  ];
  final changedTexts = [for (final i in changed) texts[i]];
  final prefixes = <List<Prediction>>[];
  for (var k = 1; k <= ledger.length; k++) {
    prefixes.add(
      await predictAll(
        predictor,
        changedTexts,
        Variant({for (final (e, _) in ledger.take(k)) e}),
        read,
      ),
    );
  }
  final classified = <int, List<Classified>>{
    for (var n = 0; n < changed.length; n++)
      changed[n]: attribute(matched[changed[n]], full[changed[n]].links, [
        for (final p in prefixes) p[n].links,
      ]),
  };
  final catalogClassified = [
    for (final t in catalog) ...?classified[index[t]!],
  ];
  final invisibleTexts = classified.values
      .where((c) => c.any((l) => l.edit == 'a3'))
      .length;
  final unpredicted = full.fold(0, (n, p) => n + p.unpredicted.length);
  stdout
    ..writeln(
      'classes over the catalog: ${catalogClassified.length} disagreeing '
      'links with darwin',
    )
    ..writeAll(classCounts(catalogClassified), '\n')
    ..writeln()
    ..writeln(
      'classes over the corpus: the prediction changes ${changed.length} '
      'texts, ${classified.values.fold(0, (n, c) => n + c.length)} '
      'disagreeing links with darwin, a3 changes $invisibleTexts texts, '
      '$unpredicted unpredicted spans; ${predictor.readings.length} texts '
      'read through probe-stages',
    )
    ..writeAll(classCounts(classified.values.expand((c) => c)), '\n')
    ..writeln();

  final slice = [
    for (final r in darwin)
      if (r.corpus.family == 'phone' ||
          r.corpus.family == 'email' ||
          r.links.any((l) => l.link.kind != 'web') ||
          r.reading.raw.any((raw) => raw.phone))
        r,
  ];
  final sliceTexts = [for (final r in slice) r.corpus.text];
  final byLocale = {
    for (final l in quotedLocales)
      if (l != locale) l: await harness.read(sliceTexts, locale: l),
  };
  final locales = localeDifferences(slice, byLocale);
  stdout
    ..writeln(
      'locale check: ${slice.length} phone and email texts under '
      '${byLocale.keys.join(', ')}: ${locales.length} locale-dependent',
    )
    ..writeAll([for (final l in locales) 'LOCALE $l'], '\n')
    ..writeln();
  final ok =
      deterministic &&
      corpus.length >= 150000 &&
      catalogRun.failed == 0 &&
      catalogRun.passed > 0 &&
      raw.isEmpty &&
      stages.values.every((found) => found.isEmpty) &&
      unedited.isEmpty &&
      wrong.isEmpty &&
      idle.isEmpty &&
      withheldWrong.isEmpty &&
      unpinned.isEmpty &&
      representatives.isEmpty;
  if (options.flags.contains('--oracle-only')) return ok;

  final kinds = {
    for (final k in (options.values['--kinds'] ?? '').split(','))
      if (k.isNotEmpty)
        LinkClass.values.firstWhere(
          (c) => c.label == k,
          orElse: () => _usage(),
        ),
  };
  final compared = [
    for (var i = 0; i < texts.length; i++)
      if (kinds.isEmpty || darwin[i].holdsOnly(kinds, full[i].links)) i,
  ];
  final assist = {
    for (final k in (options.values['--assist'] ?? '').split(','))
      if (k.isNotEmpty)
        UrlMatchKind.values.firstWhere((c) => c.name == k, orElse: _usage),
  };
  final comparedTexts = [for (final i in compared) texts[i]];
  final List<List<Link>> dart;
  if (assist.isEmpty) {
    dart = await dartReading(host.uxRoot, harness.commitDir, comparedTexts);
  } else {
    final recorded = Recorded(predictor.readings);
    dart = await recorded.readAll(comparedTexts, (t) {
      if (recorded.cutWindows(t) == null) return const [];
      return readLinks(
        t,
        (s) => recorded.assisted(s, assist),
        phones: assist.contains(UrlMatchKind.phone) ? recorded.phones : null,
      );
    }, read);
  }
  final departed = [
    for (var n = 0; n < compared.length; n++)
      ...departures(texts[compared[n]], dart[n], full[compared[n]]),
  ];
  final agreeing = [
    for (var n = 0; n < compared.length; n++)
      if (sameLinks(dart[n], full[compared[n]].links))
        ...?classified[compared[n]],
  ];
  final only =
      '${kinds.isEmpty ? '' : ' holding only ${options.values['--kinds']}'}'
      '${assist.isEmpty ? '' : ', NSDataDetector\'s ${options.values['--assist']} recorded'}';
  stdout
    ..writeln(
      'diff: ${compared.length} texts$only, ${departed.length} departures '
      'from the prediction, ${agreeing.length} disagreements with darwin by '
      'class',
    )
    ..writeAll(classCounts(agreeing), '\n')
    ..writeln()
    ..writeAll([for (final d in departed) 'DEPARTURE $d'], '\n')
    ..writeln();
  return ok && departed.isEmpty;
}

Future<bool> _stages(Harness harness, _Options options) async {
  final host = harness.host;
  final locale = options.locale;
  final seed = int.parse(options.values['--seed'] ?? '3451');
  final fresh = options.values['--fresh'];
  final threshold = switch (options.values['--threshold']) {
    final p? => double.parse(p),
    null => null,
  };
  final modelled = {
    for (final k in (options.values['--model'] ?? '').split(','))
      if (k.isNotEmpty)
        LinkClass.values.firstWhere((c) => c.label == k, orElse: _usage),
  };
  final characters = await CharacterClasses.read(harness);
  final inputs = await _corpusInputs(harness, characters);
  final corpus = fresh == null
      ? generateCorpus(seed, inputs)
      : freshSchemeTexts(seed, int.parse(fresh));
  stdout.writeln(
    header(
      host,
      commit: harness.commit,
      locale: locale,
      seed: seed,
      size: corpus.length,
    ),
  );
  final texts = [for (final c in corpus) c.text];
  Future<List<ProbeReading>> read(List<String> t) =>
      harness.readStages(t, locale: locale);
  final predictor = Predictor(await _ruleData(harness, characters));
  final staged = await read(texts);
  for (var i = 0; i < texts.length; i++) {
    predictor.readings[texts[i]] = staged[i];
  }
  final full = await predictAll(predictor, texts, Variant(allEdits), read);
  bool unicode(String t) => t.runes.any(characters.differences.contains);

  final recorded = Recorded(predictor.readings);
  final reading = await recorded.readAll(texts, (t) {
    if (recorded.cutWindows(t) == null) return const [];
    return readLinks(t, recorded.stage2, phones: recorded.phones);
  }, read);
  final outside = [
    for (var i = 0; i < texts.length; i++)
      if (!unicode(texts[i])) i,
  ];
  final edits = differing(
    [for (final i in outside) texts[i]],
    [for (final i in outside) reading[i]],
    [for (final i in outside) full[i].links],
  );
  final nonLocal = <String>[];
  var pending = [for (final i in outside) texts[i]];
  while (pending.isNotEmpty) {
    recorded.missing.clear();
    final next = <String>[];
    for (final t in pending) {
      final local = recorded.local(recorded.cutWindows(t)!);
      if (local == null) {
        next.add(t);
      } else if (!local) {
        nonLocal.add(t);
      }
    }
    if (recorded.missing.isNotEmpty) {
      final lacked = recorded.missing.toList();
      final found = await read(lacked);
      for (var i = 0; i < lacked.length; i++) {
        recorded.readings[lacked[i]] = found[i];
      }
    }
    pending = next;
  }
  recorded.windows.clear();
  final nonLocalSet = nonLocal.toSet();
  final families = <String, int>{};
  for (final c in corpus) {
    if (nonLocalSet.contains(c.text)) {
      families[c.family] = (families[c.family] ?? 0) + 1;
    }
  }
  final editsLocal = [
    for (final i in outside)
      if (!nonLocalSet.contains(texts[i]) &&
          !sameLinks(reading[i], full[i].links))
        i,
  ];
  stdout
    ..writeln(
      '(a) readLinks over recorded readings, each segment window as the text '
      'reads it: ${texts.length} texts, ${texts.length - outside.length} in '
      'the Unicode class, ${outside.length - edits.length} of the other '
      '${outside.length} give the prediction; ${recorded.requested.length} '
      'texts read',
    )
    ..writeAll([for (final d in edits) 'EDITS $d'], '\n')
    ..writeln()
    ..writeln(
      '(a) segment locality: ${nonLocal.length} of the ${outside.length} texts '
      'outside the Unicode class are read by darwin otherwise in a segment\'s '
      'window alone (${[for (final MapEntry(:key, :value) in families.entries) '$key $value'].join(', ')}), '
      'counted apart; ${editsLocal.length} of the others do not give the '
      'prediction',
    )
    ..writeAll([for (final t in nonLocal) 'NONLOCAL ${printable(t)}'], '\n')
    ..writeln();

  final all = {...texts, ...recorded.requested}.toList();
  final passes = <String>[];
  var passTexts = 0;
  for (final t in all) {
    if (unicode(t)) continue;
    passTexts++;
    final r = recorded.readings[t]!;
    final (:dart, recorded: other) = secondPass(t, r);
    if (!sameLinks(dart, other)) {
      passes.add('${printable(t)}: Dart $dart, url_detect.mm $other');
    }
  }
  stdout
    ..writeln(
      '(b) the second pass: ${passTexts - passes.length} of $passTexts texts '
      'outside the Unicode class give url_detect.mm\'s candidates',
    )
    ..writeAll([for (final d in passes) 'SECOND $d'], '\n')
    ..writeln();

  final corpusTexts = texts.toSet();
  final agree = <LinkClass, int>{};
  final total = <LinkClass, int>{};
  final requestedMiss = <LinkClass, int>{};
  final misses = <LinkClass, List<String>>{};
  for (final t in all) {
    if (unicode(t)) continue;
    for (final MapEntry(key: k, value: (:dart, recorded: other)) in model(
      t,
      recorded.readings[t]!,
    ).entries) {
      final same = sameLinks(dart, other);
      if (corpusTexts.contains(t)) {
        total[k] = (total[k] ?? 0) + 1;
        if (same) agree[k] = (agree[k] ?? 0) + 1;
      } else if (!same) {
        requestedMiss[k] = (requestedMiss[k] ?? 0) + 1;
      }
      if (!same) {
        (misses[k] ??= []).add(
          '${corpusTexts.contains(t) ? 'corpus' : 'read'} ${printable(t)}: '
          'model $dart, NSDataDetector $other',
        );
      }
    }
  }
  String percent(LinkClass k) =>
      (100 * (agree[k] ?? 0) / (total[k] ?? 1)).toStringAsFixed(2);
  var modelOk = true;
  for (final k in modelled) {
    final exact =
        (agree[k] ?? 0) == (total[k] ?? 0) && (requestedMiss[k] ?? 0) == 0;
    final met = threshold == null
        ? exact
        : 100 * (agree[k] ?? 0) >= threshold * (total[k] ?? 0);
    modelOk = modelOk && met;
  }
  final baseline = seed == 3451 && fresh == null
      ? null
      : await _modelAgreement(harness, inputs, characters, locale);
  stdout
    ..writeln(
      '(c) NSDataDetector\'s model by class, texts outside the Unicode class '
      'agreeing with url_detect.mm\'s NSDataDetector candidates:',
    )
    ..writeAll([
      for (final k in LinkClass.values)
        if (total.containsKey(k) || requestedMiss.containsKey(k))
          '  ${k.label}: ${agree[k] ?? 0} of ${total[k] ?? 0} corpus texts '
              '(${percent(k)}%), ${requestedMiss[k] ?? 0} texts read that '
              'differ${baseline == null ? '' : '; seed 3451 corpus ${baseline[k] ?? '-'}'}',
    ], '\n')
    ..writeln()
    ..writeAll([
      for (final k in modelled)
        for (final m in misses[k] ?? const <String>[]) 'MODEL ${k.label} $m',
    ], '\n')
    ..writeln();
  return editsLocal.isEmpty && passes.isEmpty && modelOk;
}

/// The model's agreement by class over the seed-3451 corpus, as `(c)`
/// reports it.
Future<Map<LinkClass, String>> _modelAgreement(
  Harness harness,
  CorpusInputs inputs,
  CharacterClasses characters,
  String locale,
) async {
  final texts = [for (final c in generateCorpus(3451, inputs)) c.text];
  final staged = await harness.readStages(texts, locale: locale);
  final agree = <LinkClass, int>{};
  final total = <LinkClass, int>{};
  for (var i = 0; i < texts.length; i++) {
    if (texts[i].runes.any(characters.differences.contains)) continue;
    for (final MapEntry(key: k, value: (:dart, :recorded)) in model(
      texts[i],
      staged[i],
    ).entries) {
      total[k] = (total[k] ?? 0) + 1;
      if (sameLinks(dart, recorded)) agree[k] = (agree[k] ?? 0) + 1;
    }
  }
  return {
    for (final k in total.keys)
      k: '${(100 * (agree[k] ?? 0) / total[k]!).toStringAsFixed(2)}%',
  };
}

Future<CorpusInputs> _corpusInputs(
  Harness harness,
  CharacterClasses characters,
) async {
  final host = harness.host;
  final entries = await harness.catalog();
  final tlds = readTlds(await host.show(harness.commit, 'src/tld.h'));
  return CorpusInputs(
    catalog: {for (final e in entries) e.text}.toList()..sort(),
    inTree: await inTreeTexts(host, harness.commit),
    asciiTlds: tlds.ascii,
    idnTlds: tlds.idn,
    categories: readCategories(
      File(
        '${host.uxRoot}/tool/url_data/unicode-17.0.0/DerivedGeneralCategory.txt',
      ).readAsStringSync(),
    ),
    unicode: characters.differences.ranges,
  );
}

Future<RuleData> _ruleData(Harness harness, CharacterClasses characters) async {
  final tlds = readTlds(await harness.host.show(harness.commit, 'src/tld.h'));
  final oracleTlds = {
    for (final t in [...tlds.ascii, ...tlds.idn, ...tlds.punycode])
      t.toLowerCase(),
  };
  final nsdd = await nsddTlds(harness);
  return RuleData(
    characters,
    tlds: oracleTlds,
    nsddBare: nsdd.bare,
    newTlds: newTlds(harness.host.uxRoot, oracleTlds),
  );
}

bool _changes(List<Prediction> a, List<Prediction> b) =>
    [for (var i = 0; i < a.length; i++) !sameLinks(a[i].links, b[i].links)]
        .any((changed) => changed);

Future<bool> _props(Harness harness) async {
  stdout
    ..writeln(header(harness.host, commit: harness.commit, locale: 'en_US'))
    ..writeAll(await props(harness), '\n')
    ..writeln();
  return true;
}

Future<bool> _win(Harness harness) async {
  final win = WinIcu(harness);
  stdout
    ..writeln(header(harness.host, commit: harness.commit, locale: 'en_US'))
    ..writeln('windows/url_detect.cpp on ICU ${win.icuVersion}');
  final suite = await run(await win.suite(), ['url_detect'], check: false);
  stdout.write(suite.stdout);
  final corpus = await win.corpus();
  final texts = [for (final (text, _) in corpus) text];
  final readings = await win.read(texts);
  final matched = await harness.replay(texts, readings);
  var native = 0;
  final replayed = <String>[];
  for (var i = 0; i < corpus.length; i++) {
    final recorded = corpus[i].$2;
    if (_same(readings[i].native, recorded)) native++;
    if (!_same(matched[i], recorded)) {
      replayed.add(
        '  ${printable(texts[i])}: recorded $recorded, XUrl.match ${matched[i]}',
      );
    }
  }
  stdout
    ..writeln(
      'corpus: ${corpus.length} cases, $native read natively as recorded',
    )
    ..writeln(
      'XUrl.match over them: ${corpus.length - replayed.length} as recorded',
    )
    ..writeAll(replayed, '\n')
    ..writeln();
  return suite.exitCode == 0 && native == corpus.length;
}

bool _same(List<Link> a, List<Link> b) =>
    a.length == b.length &&
    [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((same) => same);

class _Options {
  _Options(this.values, this.flags);

  factory _Options.parse(List<String> args) {
    final values = <String, String>{};
    final flags = <String>{};
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (!arg.startsWith('--')) _usage();
      if (_valued.contains(arg)) {
        if (i + 1 >= args.length) _usage();
        values[arg] = args[++i];
      } else if (_flags.contains(arg)) {
        flags.add(arg);
      } else {
        _usage();
      }
    }
    return _Options(values, flags);
  }

  static const _valued = {
    '--commit',
    '--locale',
    '--seed',
    '--kinds',
    '--assist',
    '--model',
    '--fresh',
    '--threshold',
    '--work',
  };
  static const _flags = {'--oracle-only'};

  final Map<String, String> values;
  final Set<String> flags;

  String get commit => values['--commit'] ?? defaultCommit;

  String get locale => values['--locale'] ?? 'en_US';

  Directory get work => Directory(
    values['--work'] ?? '${Directory.systemTemp.path}/ux_url_oracle',
  );
}

Never _usage() {
  stderr.writeln(
    'usage: dart run tool/url_oracle/oracle.dart catalog|diff|stages|props|win '
    '[--commit C] [--locale L] [--seed N] [--kinds K,...] [--assist K,...] '
    '[--oracle-only] [--model K,...] [--fresh N] [--threshold P] [--work DIR]',
  );
  exit(2);
}
