import 'dart:convert';
import 'dart:io';

import 'wire.dart';

/// The macOS build every reading is pinned to.
const pinnedProduct = '26.4';

/// The build of [pinnedProduct] every reading is pinned to.
const pinnedBuild = '25E246';

/// The oracle commit: ux master that the reference reading is taken at.
const defaultCommit = 'cae30daa';

/// A command's result, with its output decoded as UTF-8.
class Ran {
  /// The exit code and output of a finished command.
  const Ran(this.exitCode, this.stdout, this.stderr);

  /// The command's exit code.
  final int exitCode;

  /// What it wrote to stdout.
  final String stdout;

  /// What it wrote to stderr.
  final String stderr;
}

/// Runs [executable] with [arguments] in [workingDirectory], and throws a
/// [ProcessException] unless it exits 0 or [check] is false.
Future<Ran> run(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  bool check = true,
}) async {
  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  final ran = Ran(
    result.exitCode,
    result.stdout as String,
    result.stderr as String,
  );
  if (check && ran.exitCode != 0) {
    throw ProcessException(
      executable,
      arguments,
      '${ran.stdout}${ran.stderr}'.trim(),
      ran.exitCode,
    );
  }
  return ran;
}

/// The host the oracle runs on, which must be [pinnedProduct] ([pinnedBuild]).
class Host {
  Host._(this.product, this.build, this.uxRoot, this.uxHead);

  /// The host read through `sw_vers` and the ux checkout that holds the
  /// working directory; throws a [StateError] off the pinned build.
  static Future<Host> read() async {
    if (!Platform.isMacOS) {
      throw StateError(
        'the oracle runs on macOS $pinnedProduct ($pinnedBuild) only',
      );
    }
    final product = (await run('sw_vers', ['-productVersion'])).stdout.trim();
    final build = (await run('sw_vers', ['-buildVersion'])).stdout.trim();
    if (product != pinnedProduct || build != pinnedBuild) {
      throw StateError(
        'the oracle runs on macOS $pinnedProduct ($pinnedBuild) only; this host is $product ($build)',
      );
    }
    final root = (await run('git', [
      'rev-parse',
      '--show-toplevel',
    ])).stdout.trim();
    final head = (await run('git', [
      'rev-parse',
      'HEAD',
    ], workingDirectory: root)).stdout.trim();
    return Host._(product, build, root, head);
  }

  /// `sw_vers -productVersion`.
  final String product;

  /// `sw_vers -buildVersion`.
  final String build;

  /// The ux checkout's root.
  final String uxRoot;

  /// The ux checkout's HEAD.
  final String uxHead;

  /// The full SHA of [commit] in the ux checkout.
  Future<String> resolve(String commit) async => (await run('git', [
    'rev-parse',
    '--verify',
    '$commit^{commit}',
  ], workingDirectory: uxRoot)).stdout.trim();

  /// [path] at [commit], from `git show`.
  Future<String> show(String commit, String path) async => (await run('git', [
    'show',
    '$commit:$path',
  ], workingDirectory: uxRoot)).stdout;
}

/// [binary], compiled by clang++ with [arguments] from [sources], each
/// path's text, unless an earlier build made it from the same sources and
/// arguments, which `<binary>.sources` records.
Future<String> compile(
  String binary,
  Map<String, String> sources,
  List<String> arguments,
) async {
  final record = File('$binary.sources');
  final built = jsonEncode([arguments, sources]);
  if (File(binary).existsSync() &&
      record.existsSync() &&
      record.readAsStringSync() == built) {
    return binary;
  }
  for (final MapEntry(key: path, value: text) in sources.entries) {
    File(path)
      ..createSync(recursive: true)
      ..writeAsStringSync(text);
  }
  await run('clang++', [...arguments, '-o', binary]);
  record.writeAsStringSync(built);
  return binary;
}

/// [source], url_detect.mm, with a declaration of the probe's
/// ux_probe_stages after `@implementation XUrlRawMatch`, the count of
/// NSDataDetector's candidates before `if (webRe != nil) {` and a call
/// handing it every candidate before `if (raws.count == 0) return NULL;`.
String instrument(String source) {
  String insert(
    String text,
    String anchor,
    String line, {
    required bool after,
  }) {
    final at = text.indexOf(anchor);
    if (at < 0 || text.indexOf(anchor, at + 1) >= 0) {
      throw StateError('url_detect.mm holds "$anchor" other than once');
    }
    final lineStart = text.lastIndexOf('\n', at) + 1;
    final lineEnd = text.indexOf('\n', at) + 1;
    final indent = text.substring(lineStart, at);
    return after
        ? '${text.substring(0, lineEnd)}$indent$line\n${text.substring(lineEnd)}'
        : '${text.substring(0, lineStart)}$indent$line\n${text.substring(lineStart)}';
  }

  var out = insert(
    source,
    '@implementation XUrlRawMatch',
    'extern "C" void ux_probe_stages(NSArray *raws, NSUInteger nsdd);',
    after: true,
  );
  out = insert(
    out,
    'if (webRe != nil) {',
    'const NSUInteger ux_probe_nsdd = raws.count;',
    after: false,
  );
  return insert(
    out,
    'if (raws.count == 0) return NULL;',
    'ux_probe_stages(raws, ux_probe_nsdd);',
    after: false,
  );
}

/// The report header every command prints.
String header(
  Host host, {
  required String commit,
  required String locale,
  int? seed,
  int? size,
}) => [
  'macOS ${host.product} (${host.build})',
  'locale $locale',
  'ux HEAD ${host.uxHead}',
  'oracle commit $commit',
  if (seed != null) 'corpus seed $seed',
  if (size != null) 'corpus size $size',
].join('\n');

/// The oracle's builds and archives for one commit, under [work].
class Harness {
  /// The harness of [host] for the oracle [commit], a full SHA, keeping its
  /// files under [work].
  Harness(this.host, this.commit, this.work);

  /// The host it runs on.
  final Host host;

  /// The oracle commit's full SHA.
  final String commit;

  /// The directory its builds, archives and readings live in.
  final Directory work;

  String get _short => commit.substring(0, 8);

  /// The directory of this commit's builds, archive and readings.
  Directory get commitDir => Directory('${work.path}/$_short');

  /// The probe built from [commit]'s url_detect.mm and src/tld.h.
  Future<String> probe() async => _probe('probe', (source) => source);

  /// probe-stages: the probe built from [commit]'s url_detect.mm with three
  /// lines that hand its candidates to the probe before its sort.
  Future<String> stagesProbe() async => _probe('probe-stages', instrument);

  Future<String> _probe(
    String name,
    String Function(String source) edit,
  ) async {
    const mm = 'darwin/ux/Sources/ux_url_detect/url_detect.mm';
    final dir = '${commitDir.path}/$name-src';
    return compile(
      '${commitDir.path}/$name',
      {
        '$dir/probe.mm': File('${host.uxRoot}/tool/url_oracle/probe.mm')
            .readAsStringSync(),
        '$dir/$mm': edit(await host.show(commit, mm)),
        '$dir/src/tld.h': await host.show(commit, 'src/tld.h'),
      },
      [
        '-std=c++17',
        '-fobjc-arc',
        '-O2',
        '-framework',
        'Foundation',
        '$dir/probe.mm',
        '$dir/$mm',
      ],
    );
  }

  /// [commit]'s tree from `git archive`, its packages resolved.
  Future<Directory> tree() async {
    final tree = Directory('${commitDir.path}/tree');
    final ready = File('${tree.path}/.oracle_ready');
    if (ready.existsSync()) return tree;
    if (tree.existsSync()) tree.deleteSync(recursive: true);
    tree.createSync(recursive: true);
    final archive = '${commitDir.path}/tree.tar';
    await run('git', [
      'archive',
      '--output',
      archive,
      commit,
    ], workingDirectory: host.uxRoot);
    await run('tar', ['-xf', archive, '-C', tree.path]);
    File(archive).deleteSync();
    await run('flutter', ['pub', 'get'], workingDirectory: tree.path);
    ready.writeAsStringSync(commit);
    return tree;
  }

  /// The readings of [texts] under [locale], one per text, by [probe] or
  /// else the darwin probe.
  Future<List<ProbeReading>> read(
    List<String> texts, {
    required String locale,
    String? probe,
  }) async => _read(texts, locale, probe ?? await this.probe(), 'texts');

  /// probe-stages' readings of [texts] under [locale], one per text, each
  /// with its candidates.
  Future<List<ProbeReading>> readStages(
    List<String> texts, {
    required String locale,
  }) async => _read(texts, locale, await stagesProbe(), 'stages');

  Future<List<ProbeReading>> _read(
    List<String> texts,
    String locale,
    String probe,
    String mode,
  ) async {
    final dir = Directory('${commitDir.path}/$mode-$locale')
      ..createSync(recursive: true);
    final input = File('${dir.path}/texts')
      ..writeAsStringSync(_lines(texts.map(toUtf16Base64)));
    final output = File('${dir.path}/probe');
    await run(probe, [mode, input.path, output.path, '-AppleLocale', locale]);
    final readings = output
        .readAsLinesSync()
        .map(ProbeReading.fromLine)
        .toList();
    if (readings.length != texts.length) {
      throw StateError(
        'the probe read ${readings.length} of ${texts.length} texts',
      );
    }
    return readings;
  }

  /// [commit]'s XUrl.match of each of [texts], whose XUrl.debugDetect answers
  /// the buffer of its [readings].
  Future<List<List<Link>>> replay(
    List<String> texts,
    List<ProbeReading> readings,
  ) async {
    final tree = await this.tree();
    final dir = await _scratch('replay');
    File('${dir.path}/texts')
        .writeAsStringSync(_lines(texts.map(toUtf16Base64)));
    File('${dir.path}/probe')
        .writeAsStringSync(_lines([for (final r in readings) _probeLine(r)]));
    final oracle = _installOracle(tree);
    File('${host.uxRoot}/tool/url_oracle/replay/replay_test.dart')
        .copySync('${oracle.path}/replay_test.dart');
    final ran = await _flutterTest(
      tree,
      ['test/oracle/replay_test.dart'],
      {'UX_ORACLE_DIR': dir.path},
    );
    if (ran.failed > 0 || ran.passed != 1) {
      throw StateError('the replay failed:\n${ran.output}');
    }
    return [
      for (final line in File('${dir.path}/match').readAsLinesSync())
        [
          for (final l in jsonDecode(line) as List<Object?>)
            Link.fromJson(l! as List<Object?>),
        ],
    ];
  }

  /// Each expectLinks call of test/url: its text, expected links and apple
  /// links, where it gives them.
  Future<List<CatalogEntry>> catalog() async {
    final tree = await _installCatalog();
    final dir = await _scratch('collect');
    final collect = Directory('${dir.path}/collect')..createSync();
    final ran = await _flutterTest(tree, _catalogArgs, {
      'UX_ORACLE_MODE': 'collect',
      'UX_ORACLE_DIR': dir.path,
    });
    if (ran.failed > 0) {
      throw StateError('collecting the catalog failed:\n${ran.output}');
    }
    final files = collect.listSync().whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    List<Link> links(Object? json) => [
      for (final l in json! as List<Object?>)
        Link.fromJson(l! as List<Object?>),
    ];
    return [
      for (final file in files)
        for (final line in file.readAsLinesSync())
          if (jsonDecode(line) case [
            final String text,
            final Object expected,
            ...final apple,
          ])
            CatalogEntry(
              fromUtf16Base64(text),
              links(expected),
              apple.isEmpty ? null : links(apple.single),
            ),
    ];
  }

  /// The texts test/url passes to expectLinks, each once, in the order first
  /// seen.
  Future<List<String>> catalogTexts() async =>
      {for (final e in await catalog()) e.text}.toList();

  /// test/url run against [commit]'s XUrl.match, with each text's
  /// XUrl.debugDetect answering the buffer of its reading in [readings].
  Future<TestRun> checkCatalog(
    List<String> texts,
    List<ProbeReading> readings,
  ) async {
    final tree = await _installCatalog();
    final dir = await _scratch('check');
    File('${dir.path}/readings').writeAsStringSync(
      _lines([
        for (var i = 0; i < texts.length; i++)
          '${toUtf16Base64(texts[i])} ${_probeLine(readings[i])}',
      ]),
    );
    return _flutterTest(tree, _catalogArgs, {'UX_ORACLE_DIR': dir.path});
  }

  static const _catalogArgs = [
    '--run-skipped',
    '--exclude-tags',
    'performance',
    'test/url',
  ];

  Future<Directory> _installCatalog() async {
    final tree = await this.tree();
    _installOracle(tree);
    final url = Directory('${tree.path}/test/url');
    if (url.existsSync()) url.deleteSync(recursive: true);
    url.createSync(recursive: true);
    for (final file in Directory(
      '${host.uxRoot}/test/url',
    ).listSync().whereType<File>()) {
      final name = file.uri.pathSegments.last;
      if (name.endsWith('.dart') && name != 'links.dart') {
        file.copySync('${url.path}/$name');
      }
    }
    File('${host.uxRoot}/tool/url_oracle/replay/links.dart')
        .copySync('${url.path}/links.dart');
    File('${host.uxRoot}/dart_test.yaml')
        .copySync('${tree.path}/dart_test.yaml');
    return tree;
  }

  Directory _installOracle(Directory tree) {
    final oracle = Directory('${tree.path}/test/oracle')
      ..createSync(recursive: true);
    File('${host.uxRoot}/tool/url_oracle/wire.dart')
        .copySync('${oracle.path}/wire.dart');
    return oracle;
  }

  Future<Directory> _scratch(String name) async {
    final dir = Directory('${commitDir.path}/$name');
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    return dir..createSync(recursive: true);
  }

  Future<TestRun> _flutterTest(
    Directory tree,
    List<String> args,
    Map<String, String> defines,
  ) async {
    final report = File('${commitDir.path}/report.json');
    final ran = await run(
      'flutter',
      [
        'test',
        '--no-pub',
        for (final e in defines.entries) '--dart-define=${e.key}=${e.value}',
        '--file-reporter',
        'json:${report.path}',
        ...args,
      ],
      workingDirectory: tree.path,
      check: false,
    );
    return TestRun.parse(
      report.readAsLinesSync(),
      '${ran.stdout}${ran.stderr}',
    );
  }
}

/// One expectLinks call of the catalog.
class CatalogEntry {
  /// The call for [text] that expects [expected], and [apple] as the darwin
  /// reading where it departs from it.
  const CatalogEntry(this.text, this.expected, this.apple);

  /// The text.
  final String text;

  /// The links the catalog expects.
  final List<Link> expected;

  /// The darwin reading where [expected] departs from it.
  final List<Link>? apple;
}

/// The outcome of one `flutter test` run, from its JSON reporter.
class TestRun {
  TestRun._(this.passed, this.failed, this.skipped, this.failures, this.output);

  /// The run whose JSON reporter wrote [events] and whose console showed
  /// [output].
  factory TestRun.parse(List<String> events, String output) {
    final names = <int, String>{};
    final errors = <int, List<String>>{};
    var passed = 0;
    var failed = 0;
    var skipped = 0;
    final failures = <String>[];
    for (final line in events) {
      final event = jsonDecode(line) as Map<String, Object?>;
      switch (event['type']) {
        case 'testStart':
          final test = event['test']! as Map<String, Object?>;
          names[test['id']! as int] = test['name']! as String;
        case 'error':
          (errors[event['testID']! as int] ??= []).add('${event['error']}');
        case 'testDone':
          if (event['hidden'] == true) break;
          final id = event['testID']! as int;
          if (event['skipped'] == true) {
            skipped++;
          } else if (event['result'] == 'success') {
            passed++;
          } else {
            failed++;
            failures.add(
              '${names[id]}\n  ${(errors[id] ?? const []).join('\n  ')}',
            );
          }
      }
    }
    return TestRun._(passed, failed, skipped, failures, output);
  }

  /// Tests that passed.
  final int passed;

  /// Tests that failed or errored.
  final int failed;

  /// Tests that were skipped.
  final int skipped;

  /// Each failed test's name and errors.
  final List<String> failures;

  /// The console output of the run.
  final String output;
}

String _probeLine(ProbeReading r) => jsonEncode({
  'b': base64Encode(r.buffer),
  'r': [
    for (final raw in r.raw)
      [
        raw.start,
        raw.end,
        if (raw.phone) 'p' else 'l',
        toUtf16Base64(raw.value),
      ],
  ],
});

String _lines(Iterable<String> lines) {
  final out = StringBuffer();
  for (final line in lines) {
    out.writeln(line);
  }
  return out.toString();
}
