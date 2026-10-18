// Generates lib/src/url/unicode.dart, the character classes the link
// detector reads, from tool/url_data/unicode-<version>/.
//
//   dart run tool/update_unicode.dart            writes lib/src/url/unicode.dart
//   dart run tool/update_unicode.dart --check    exits 1 where it differs
//   dart run tool/update_unicode.dart --update V fetches Unicode V's files
import 'dart:io';

const _output = 'lib/src/url/unicode.dart';

const _files = {
  'DerivedGeneralCategory.txt': 'ucd',
  'DerivedCoreProperties.txt': 'ucd',
  'IdnaMappingTable.txt': 'idna',
};

/// Each generated class: its constant, its doc, and the general categories
/// or properties that make it up.
const _classes = [
  ('letter', 'General category L.', ['Lu', 'Ll', 'Lt', 'Lm', 'Lo']),
  ('mark', 'General category M.', ['Mn', 'Mc', 'Me']),
  ('digit', 'General category Nd.', ['Nd']),
  ('format', 'General category Cf.', ['Cf']),
  ('symbol', 'General categories So and Sk.', ['So', 'Sk']),
  ('connector', 'General category Pc.', ['Pc']),
  ('alphabetic', 'The Alphabetic property.', ['Alphabetic']),
  ('extend', 'The Grapheme_Extend property.', ['Grapheme_Extend']),
  ('separator', 'General category Z.', ['Zs', 'Zl', 'Zp']),
];

Future<void> main(List<String> args) async {
  final root = Directory.current.path;
  if (args.length == 2 && args[0] == '--update') {
    await _fetch(root, args[1]);
  } else if (!(args.isEmpty || (args.length == 1 && args[0] == '--check'))) {
    stderr.writeln(
      'usage: dart run tool/update_unicode.dart [--check | --update VERSION]',
    );
    exit(2);
  }
  final version = _newest(root);
  final generated = generate(
    version,
    File('$root/tool/url_data/unicode-$version/DerivedGeneralCategory.txt')
        .readAsStringSync(),
    File('$root/tool/url_data/unicode-$version/DerivedCoreProperties.txt')
        .readAsStringSync(),
  );
  final out = File('$root/$_output');
  if (args.isNotEmpty && args[0] == '--check') {
    if (!out.existsSync() || out.readAsStringSync() != generated) {
      stderr.writeln(
        '$_output differs from its generation from Unicode $version',
      );
      exit(1);
    }
    stdout.writeln('$_output matches its generation from Unicode $version');
    return;
  }
  out.writeAsStringSync(generated);
  stdout.writeln('wrote $_output from Unicode $version');
}

/// The newest version under tool/url_data/unicode-*.
String _newest(String root) {
  final versions = [
    for (final d in Directory('$root/tool/url_data').listSync())
      if (RegExp(r'unicode-(\d+)\.(\d+)\.(\d+)$').firstMatch(d.path)
          case final m?)
        [for (var i = 1; i <= 3; i++) int.parse(m[i]!)],
  ];
  if (versions.isEmpty) {
    stderr.writeln('tool/url_data holds no unicode-<version> directory');
    exit(1);
  }
  versions.sort((a, b) {
    for (var i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i].compareTo(b[i]);
    }
    return 0;
  });
  return versions.last.join('.');
}

Future<void> _fetch(String root, String version) async {
  final dir = Directory('$root/tool/url_data/unicode-$version')
    ..createSync(recursive: true);
  final client = HttpClient();
  try {
    for (final MapEntry(key: name, value: path) in _files.entries) {
      final url = 'https://www.unicode.org/Public/$version/$path/$name';
      final response = await (await client.getUrl(Uri.parse(url))).close();
      if (response.statusCode != 200) {
        stderr.writeln('$url: HTTP ${response.statusCode}');
        exit(1);
      }
      final bytes = await response.fold<List<int>>([], (a, b) => a..addAll(b));
      File('${dir.path}/$name').writeAsBytesSync(bytes);
      stdout.writeln('fetched $url');
    }
  } finally {
    client.close();
  }
}

/// lib/src/url/unicode.dart for Unicode [version], from its
/// DerivedGeneralCategory.txt [categories] and DerivedCoreProperties.txt
/// [properties].
String generate(String version, String categories, String properties) {
  final values = <String, List<(int, int)>>{};
  final line = RegExp(r'^([0-9A-F]+)(?:\.\.([0-9A-F]+))?\s*;\s*(\w+)');
  for (final source in [categories, properties]) {
    for (final l in source.split('\n')) {
      final m = line.firstMatch(l);
      if (m == null) continue;
      (values[m[3]!] ??= []).add((
        int.parse(m[1]!, radix: 16),
        int.parse(m[2] ?? m[1]!, radix: 16),
      ));
    }
  }
  final bounds = <int, int>{};
  for (final (bit, (_, _, names)) in _classes.indexed) {
    for (final name in names) {
      final ranges = values[name];
      if (ranges == null) throw StateError('Unicode $version has no $name');
      for (final (first, last) in ranges) {
        bounds[first] = (bounds[first] ?? 0) ^ (1 << bit);
        bounds[last + 1] = (bounds[last + 1] ?? 0) ^ (1 << bit);
      }
    }
  }
  final starts = <int>[0];
  final bits = <int>[0];
  var current = 0;
  for (final at in bounds.keys.toList()..sort()) {
    current ^= bounds[at]!;
    if (at == starts.last) {
      bits[bits.length - 1] = current;
    } else if (current != bits.last) {
      starts.add(at);
      bits.add(current);
    }
  }
  final out = StringBuffer()
    ..writeln(
      '// Generated by tool/update_unicode.dart from Unicode $version\'s',
    )
    ..writeln('// DerivedGeneralCategory.txt and DerivedCoreProperties.txt.')
    ..writeln();
  for (final (bit, (name, doc, _)) in _classes.indexed) {
    out
      ..writeln('/// $doc')
      ..writeln('const int $name = ${1 << bit};')
      ..writeln();
  }
  out
    ..writeln('/// The classes of the code point [cp], as a union of the class')
    ..writeln('/// constants.')
    ..writeln('int classesOf(int cp) {')
    ..writeln('  final (starts, bits) = _table;')
    ..writeln('  var lo = 0;')
    ..writeln('  var hi = starts.length;')
    ..writeln('  while (hi - lo > 1) {')
    ..writeln('    final mid = (lo + hi) >> 1;')
    ..writeln('    if (starts[mid] <= cp) {')
    ..writeln('      lo = mid;')
    ..writeln('    } else {')
    ..writeln('      hi = mid;')
    ..writeln('    }')
    ..writeln('  }')
    ..writeln('  return bits[lo];')
    ..writeln('}')
    ..writeln()
    ..writeln('final (List<int>, List<int>) _table = () {')
    ..writeln('  final starts = <int>[];')
    ..writeln('  final bits = <int>[];')
    ..writeln('  var at = 0;')
    ..writeln("  for (final entry in _ranges.split(',')) {")
    ..writeln("    final colon = entry.indexOf(':');")
    ..writeln('    at += int.parse(entry.substring(0, colon), radix: 16);')
    ..writeln('    starts.add(at);')
    ..writeln('    bits.add(int.parse(entry.substring(colon + 1), radix: 16));')
    ..writeln('  }')
    ..writeln('  return (starts, bits);')
    ..writeln('}();')
    ..writeln()
    ..writeln(
      '/// Each range of code points with one set of classes: the distance',
    )
    ..writeln("/// from the previous range's start and the classes, in hex.")
    ..write(_ranges(starts, bits));
  return out.toString();
}

String _ranges(List<int> starts, List<int> bits) {
  final entries = [
    for (var i = 0; i < starts.length; i++)
      '${(starts[i] - (i == 0 ? 0 : starts[i - 1])).toRadixString(16)}:'
          '${bits[i].toRadixString(16)}',
  ];
  final lines = <String>[];
  var line = StringBuffer();
  for (var i = 0; i < entries.length; i++) {
    final item = i + 1 < entries.length ? '${entries[i]},' : entries[i];
    if (line.length + item.length > 74) {
      lines.add(line.toString());
      line = StringBuffer();
    }
    line.write(item);
  }
  lines.add(line.toString());
  return 'const _ranges =\n${lines.map((l) => "    '$l'").join('\n')};\n';
}
