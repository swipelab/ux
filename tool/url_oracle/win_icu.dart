import 'dart:io';

import 'harness.dart';
import 'wire.dart';

/// Homebrew's icu4c@78, which windows/url_detect.cpp builds against.
const icuPrefix = '/opt/homebrew/opt/icu4c@78';

/// An oracle commit's windows/url_detect.cpp, built against [icuPrefix] with
/// tool/url_oracle/win_icu's stand-ins for `<windows.h>` and `<icu.h>`.
class WinIcu {
  /// The Windows detector of [harness]'s commit.
  WinIcu(this.harness);

  /// The harness of the commit whose sources it builds.
  final Harness harness;

  Directory get _dir => Directory('${harness.commitDir.path}/win');

  /// The ICU version [icuPrefix]'s headers declare.
  String get icuVersion {
    final header = File('$icuPrefix/include/unicode/uvernum.h')
        .readAsStringSync();
    return RegExp(r'#define U_ICU_VERSION "([^"]+)"').firstMatch(header)![1]!;
  }

  static const _sources = [
    'windows/url_detect.cpp',
    'windows/url_detect.h',
    'src/tld.h',
    'windows/test/url_detect_test.cpp',
    'windows/test/check.h',
    'windows/test/ux_test.cpp',
  ];

  Future<void> _write() async {
    for (final path in _sources) {
      File('${_dir.path}/$path')
        ..createSync(recursive: true)
        ..writeAsStringSync(await harness.host.show(harness.commit, path));
    }
  }

  List<String> get _flags => [
    '-std=c++17',
    '-O2',
    '-D__declspec(x)=',
    '-I${harness.host.uxRoot}/tool/url_oracle/win_icu',
    '-I${_dir.path}/src',
    '-I$icuPrefix/include',
  ];

  List<String> get _icu => [
    '-L$icuPrefix/lib',
    '-licuuc',
    '-licui18n',
    '-licudata',
    '-Wl,-rpath,$icuPrefix/lib',
  ];

  /// ux_test built from the commit's url_detect suite, with every other suite
  /// ux_test.cpp declares defined empty.
  Future<String> suite() async {
    final binary = File('${_dir.path}/ux_test');
    if (binary.existsSync()) return binary.path;
    await _write();
    final main = File('${_dir.path}/windows/test/ux_test.cpp');
    final suites = RegExp(r'^void (\w+Suite)\(\);', multiLine: true)
        .allMatches(main.readAsStringSync())
        .map((m) => m[1]!)
        .where((name) => name != 'UrlDetectSuite');
    final stubs = File('${_dir.path}/stubs.cpp')
      ..writeAsStringSync([for (final s in suites) 'void $s() {}\n'].join());
    await run('clang++', [
      ..._flags,
      '${_dir.path}/windows/url_detect.cpp',
      '${_dir.path}/windows/test/url_detect_test.cpp',
      main.path,
      stubs.path,
      ..._icu,
      '-o',
      binary.path,
    ]);
    return binary.path;
  }

  /// tool/url_oracle/probe.mm linked with the commit's Windows detector.
  Future<String> probe() async {
    final binary = File('${_dir.path}/probe');
    if (binary.existsSync()) return binary.path;
    await _write();
    await run('clang++', [
      ..._flags,
      '-fobjc-arc',
      '-framework',
      'Foundation',
      '${harness.host.uxRoot}/tool/url_oracle/probe.mm',
      '${_dir.path}/windows/url_detect.cpp',
      ..._icu,
      '-o',
      binary.path,
    ]);
    return binary.path;
  }

  /// The detector's readings of [texts], one per text.
  Future<List<ProbeReading>> read(List<String> texts) async =>
      harness.read(texts, locale: 'en_US', probe: await probe());

  /// The commit's url_detect_test.cpp corpus: each case's text and recorded
  /// links.
  Future<List<(String, List<Link>)>> corpus() async {
    await _write();
    return windowsCorpus(
      File('${_dir.path}/windows/test/url_detect_test.cpp').readAsStringSync(),
    );
  }
}

/// The cases of url_detect_test.cpp's [source]: each case's text and
/// recorded links.
List<(String, List<Link>)> windowsCorpus(String source) {
  final step = RegExp(r'const std::u16string kStepText = u"((?:[^"\\]|\\.)*)";')
      .firstMatch(source)![1]!;
  final body = source.substring(
    source.indexOf('corpus = {'),
    source.indexOf('return corpus;'),
  );
  final cases = RegExp(
    r'\{"(?:[^"\\]|\\.)*",\s*(kStepText|u"((?:[^"\\]|\\.)*)"),\s*\{(.*?)\}\},?\n',
    dotAll: true,
  );
  final links = RegExp(
    r'\{(\d+),\s*(\d+),\s*k(Web|Email|Phone),\s*(?:u8)?"((?:[^"\\]|\\.)*)"\}',
  );
  return [
    for (final c in cases.allMatches(body))
      (
        unescapeCpp(c[1] == 'kStepText' ? step : c[2]!),
        [
          for (final l in links.allMatches(c[3]!))
            Link(
              int.parse(l[1]!),
              int.parse(l[2]!),
              l[3]!.toLowerCase(),
              unescapeCpp(l[4]!),
            ),
        ],
      ),
  ];
}
