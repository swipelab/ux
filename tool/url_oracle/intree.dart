import 'harness.dart';
import 'win_icu.dart';
import 'wire.dart';

/// The texts the in-tree url tests read at [commit]: the example's
/// url_match_test, url_test's XUrl.match group and windows/test's
/// url_detect_test.cpp corpus.
Future<List<String>> inTreeTexts(Host host, String commit) async => [
  ...dartCalls(
    await host.show(commit, 'example/integration_test/url_match_test.dart'),
    const ['XUrl.match('],
  ),
  ...dartCalls(await host.show(commit, 'test/url_test.dart'), const [
    'XUrl.match(',
    '_expectMatch(',
  ]),
  for (final (text, _) in windowsCorpus(
    await host.show(commit, 'windows/test/url_detect_test.cpp'),
  ))
    text,
];

/// The string each call to one of [callees] in [source] passes first, where
/// it passes a literal or a `const` its test declares with one.
List<String> dartCalls(String source, List<String> callees) {
  final texts = <String>[];
  for (final callee in callees) {
    for (
      var at = source.indexOf(callee);
      at >= 0;
      at = source.indexOf(callee, at + 1)
    ) {
      final text =
          _literals(source, at + callee.length) ??
          _constant(source, at + callee.length);
      if (text != null) texts.add(text);
    }
  }
  return texts;
}

/// The value of the `const` named at [at] in [source], where the test
/// around [at] declares it before [at].
String? _constant(String source, int at) {
  final name = RegExp(r'\s*([A-Za-z_]\w*)').matchAsPrefix(source, at)?[1];
  if (name == null) return null;
  final test = source.lastIndexOf('test(', at);
  final declared = RegExp('const $name = ')
      .allMatches(source.substring(0, at), test < 0 ? 0 : test)
      .lastOrNull;
  return declared == null ? null : _literals(source, declared.end);
}

/// The value of the adjacent Dart string literals at [at] in [source], or
/// null where none starts there.
String? _literals(String source, int at) {
  final value = StringBuffer();
  var any = false;
  var i = at;
  while (true) {
    while (i < source.length && ' \t\r\n'.contains(source[i])) {
      i++;
    }
    if (i >= source.length || !(source[i] == "'" || source[i] == '"')) break;
    final quote = source[i++];
    while (source[i] != quote) {
      if (source[i] != r'\') {
        value.write(source[i++]);
        continue;
      }
      final kind = source[i + 1];
      if (kind == 'u' && source[i + 2] == '{') {
        final close = source.indexOf('}', i);
        value.writeCharCode(
          int.parse(source.substring(i + 3, close), radix: 16),
        );
        i = close + 1;
      } else if (kind == 'u') {
        value.writeCharCode(
          int.parse(source.substring(i + 2, i + 6), radix: 16),
        );
        i += 6;
      } else {
        value.write(const {'n': '\n', 't': '\t', 'r': '\r'}[kind] ?? kind);
        i += 2;
      }
    }
    i++;
    any = true;
  }
  return any ? value.toString() : null;
}

/// The ASCII entries of kTlds, its xn-- entries and the labels of kIdnTlds
/// in [source], the text of src/tld.h.
({List<String> ascii, List<String> punycode, List<String> idn}) readTlds(
  String source,
) {
  List<String> entries(String name) {
    final start = source.indexOf('$name[] = {');
    final body = source.substring(start, source.indexOf('};', start));
    return [
      for (final m in RegExp(r'u"((?:[^"\\]|\\.)*)"').allMatches(body))
        unescapeCpp(m[1]!),
    ];
  }

  final tlds = entries('kTlds');
  return (
    ascii: [
      for (final t in tlds)
        if (!t.startsWith('xn--')) t,
    ],
    punycode: [
      for (final t in tlds)
        if (t.startsWith('xn--')) t,
    ],
    idn: entries('kIdnTlds'),
  );
}
