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

import 'harness.dart';
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
