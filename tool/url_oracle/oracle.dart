// The darwin oracle: XUrl.match at an oracle commit over that commit's
// url_detect.mm and NSDataDetector, on macOS 26.4 (25E246).
//
//   dart run tool/url_oracle/oracle.dart catalog [--commit C] [--locale L]
//   dart run tool/url_oracle/oracle.dart diff [--oracle-only] [--kinds K,...] [--seed N] [--commit C] [--locale L]
//   dart run tool/url_oracle/oracle.dart props [--commit C]
//   dart run tool/url_oracle/oracle.dart win [--commit C]
//
// It writes only under --work, a directory outside the checkout.
import 'dart:io';

import 'corpus.dart';
import 'diff.dart';
import 'classes.dart';
import 'harness.dart';
import 'intree.dart';
import 'props.dart';
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
  final seed = int.parse(options.values['--seed'] ?? '3451');
  final catalog = await harness.catalogTexts();
  final tlds = readTlds(await host.show(harness.commit, 'src/tld.h'));
  final inputs = CorpusInputs(
    catalog: catalog,
    inTree: await inTreeTexts(host, harness.commit),
    asciiTlds: tlds.ascii,
    idnTlds: tlds.idn,
    categories: readCategories(
      File(
        '${host.uxRoot}/tool/url_data/unicode-17.0.0/DerivedGeneralCategory.txt',
      ).readAsStringSync(),
    ),
  );
  final corpus = generateCorpus(seed, inputs);
  final deterministic =
      encodeCorpus(corpus) == encodeCorpus(generateCorpus(seed, inputs));
  final head = header(
    host,
    commit: harness.commit,
    locale: options.locale,
    seed: seed,
    size: corpus.length,
  );
  stdout.writeln(head);
  final texts = [for (final c in corpus) c.text];
  final probes = await harness.read(texts, locale: options.locale);
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

  final byText = {for (var i = 0; i < texts.length; i++) texts[i]: probes[i]};
  final catalogRun = await harness.checkCatalog(catalog, [
    for (final t in catalog) byText[t]!,
  ]);
  final quoted = await harness.read([
    for (final (text, _) in rawQuotes) text,
  ], locale: options.locale);
  final raw = rawMismatches({
    for (var i = 0; i < rawQuotes.length; i++) rawQuotes[i].$1: quoted[i].raw,
  });
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
      'self-check: raw NSDataDetector quotes ${rawQuotes.length - raw.length} '
      'of ${rawQuotes.length} reproduced',
    )
    ..writeAll([for (final m in raw) 'RAW $m'], '\n')
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
    for (final locale in const ['en_US', 'en_GB', 'de_DE', 'ja_JP'])
      if (locale != options.locale)
        locale: await harness.read(sliceTexts, locale: locale),
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
      raw.isEmpty;
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
    for (final r in darwin)
      if (kinds.isEmpty || r.holdsOnly(kinds)) r,
  ];
  final dart = await dartReading(host.uxRoot, harness.commitDir, [
    for (final r in compared) r.corpus.text,
  ]);
  final found = disagreements(compared, dart);
  final byClass = <String, int>{};
  final unclassified = <Disagreement>[];
  for (final d in found) {
    final c = classes.where((c) => c.holds(d)).firstOrNull;
    if (c == null) {
      unclassified.add(d);
    } else {
      byClass[c.name] = (byClass[c.name] ?? 0) + 1;
    }
  }
  final only = kinds.isEmpty
      ? ''
      : ' holding only ${options.values['--kinds']}';
  stdout
    ..writeln(
      'diff: ${compared.length} texts$only, ${found.length} disagreeing '
      'links, ${unclassified.length} unclassified',
    )
    ..writeAll([
      for (final c in classes) '  ${c.name}: ${byClass[c.name] ?? 0}',
    ], '\n')
    ..writeln()
    ..writeAll([for (final d in unclassified) 'UNCLASSIFIED $d'], '\n')
    ..writeln();
  return ok && unclassified.isEmpty;
}

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
    'usage: dart run tool/url_oracle/oracle.dart catalog|diff|props|win '
    '[--commit C] [--locale L] [--seed N] [--kinds K,...] [--oracle-only] [--work DIR]',
  );
  exit(2);
}
