import 'dart:convert';
import 'dart:io';

import 'corpus.dart';
import 'harness.dart';
import 'intree.dart';
import 'wire.dart';

/// A set of code points, as sorted inclusive ranges.
class CodePoints {
  CodePoints._(this.ranges);

  /// The set [ranges] covers.
  factory CodePoints.of(Iterable<(int, int)> ranges) {
    final sorted = ranges.toList()..sort((a, b) => a.$1.compareTo(b.$1));
    final merged = <(int, int)>[];
    for (final (first, last) in sorted) {
      if (merged.isNotEmpty && first <= merged.last.$2 + 1) {
        final (start, end) = merged.removeLast();
        merged.add((start, last > end ? last : end));
      } else {
        merged.add((first, last));
      }
    }
    return CodePoints._(merged);
  }

  /// The sorted, disjoint inclusive ranges.
  final List<(int, int)> ranges;

  /// How many code points the set holds.
  int get length => ranges.fold(0, (n, r) => n + r.$2 - r.$1 + 1);

  /// The code points in this set or [other].
  CodePoints operator |(CodePoints other) =>
      CodePoints.of([...ranges, ...other.ranges]);

  /// The code points in this set and not in [other].
  CodePoints operator -(CodePoints other) {
    final out = <(int, int)>[];
    var j = 0;
    for (var (first, last) in ranges) {
      while (j < other.ranges.length && other.ranges[j].$2 < first) {
        j++;
      }
      var k = j;
      while (first <= last) {
        if (k >= other.ranges.length || other.ranges[k].$1 > last) {
          out.add((first, last));
          break;
        }
        final (oFirst, oLast) = other.ranges[k];
        if (oFirst > first) out.add((first, oFirst - 1));
        first = oLast + 1;
        k++;
      }
    }
    return CodePoints._(out);
  }

  @override
  String toString() => ranges
      .map((r) => r.$1 == r.$2 ? _hex(r.$1) : '${_hex(r.$1)}..${_hex(r.$2)}')
      .join(' ');
}

String _hex(int c) => 'U+${c.toRadixString(16).toUpperCase().padLeft(4, '0')}';

/// The code points [source], a Unicode data file, gives [property].
CodePoints property(String source, String property) => CodePoints.of([
  for (final m in RegExp(
    r'^([0-9A-F]+)(?:\.\.([0-9A-F]+))?\s*;\s*(\w+)',
    multiLine: true,
  ).allMatches(source))
    if (m[3] == property)
      (int.parse(m[1]!, radix: 16), int.parse(m[2] ?? m[1]!, radix: 16)),
]);

/// The props report: where macOS's character classes differ from Unicode
/// 17.0.0's, and the TLDs NSDataDetector links a host or an email on.
Future<List<String>> props(Harness harness) async {
  final host = harness.host;
  final data = '${host.uxRoot}/tool/url_data/unicode-17.0.0';
  final categories = readCategories(
    File('$data/DerivedGeneralCategory.txt').readAsStringSync(),
  );
  CodePoints category(List<String> names) =>
      CodePoints.of([for (final n in names) ...?categories[n]]);
  final alphabetic = property(
    File('$data/DerivedCoreProperties.txt').readAsStringSync(),
    'Alphabetic',
  );
  final letters = category(['Lu', 'Ll', 'Lt', 'Lm', 'Lo']);
  final marks = category(['Mn', 'Mc', 'Me']);
  final nd = category(['Nd']);
  final word =
      alphabetic |
      marks |
      nd |
      category(['Pc']) |
      CodePoints.of([(0x200C, 0x200D)]);
  final space =
      category(['Zs', 'Zl', 'Zp']) |
      CodePoints.of([(0x09, 0x0A), (0x0C, 0x0D)]);

  final out = File('${harness.commitDir.path}/props.json');
  await run(await harness.probe(), ['props', out.path]);
  final mac = jsonDecode(out.readAsStringSync()) as Map<String, Object?>;
  CodePoints macSet(String name) => CodePoints.of([
    for (final r in (mac[name]! as List<Object?>).cast<List<Object?>>())
      (r[0]! as int, r[1]! as int),
  ]);
  final letterSet = macSet('letter') - marks;
  final report = <String>[];
  void compare(String name, CodePoints unicode, CodePoints macOS) {
    final onlyUnicode = unicode - macOS;
    final onlyMac = macOS - unicode;
    report
      ..add('$name: ${onlyUnicode.length} only in Unicode 17.0.0: $onlyUnicode')
      ..add('$name: ${onlyMac.length} only on macOS: $onlyMac');
  }

  compare('L against letterCharacterSet without M', letters, letterSet);
  report.add(
    'letterCharacterSet holds ${(macSet('letter') - letters).length} code '
    'points outside L, ${(macSet('letter') - letters - marks).length} of them '
    'outside M',
  );
  compare('Nd against decimalDigitCharacterSet', nd, macSet('digit'));
  compare(
    r'Alphabetic+M+Nd+Pc+U+200C+U+200D against ICU \w',
    word,
    macSet('word'),
  );
  compare(r'[\t\n\f\r\p{Z}] against ICU \s', space, macSet('space'));

  final tlds = readTlds(await host.show(harness.commit, 'src/tld.h'));
  final all = [...tlds.ascii, ...tlds.idn];
  final texts = [
    for (final t in all) ...['see bücher.$t x', 'see www.bücher.$t x'],
    for (final t in tlds.idn) ...['ops@example.$t', ' ops@example.$t'],
  ];
  final readings = await harness.read(texts, locale: 'en_US');
  bool linksWhole(ProbeReading r, int start, int length, String kind) =>
      r.native.any(
        (l) => l.start == start && l.end == start + length && l.kind == kind,
      );
  final bare = <String>[];
  final www = <String>[];
  for (var i = 0; i < all.length; i++) {
    final t = all[i];
    if (linksWhole(readings[2 * i], 4, 'bücher.$t'.length, 'web')) bare.add(t);
    if (linksWhole(readings[2 * i + 1], 4, 'www.bücher.$t'.length, 'web')) {
      www.add(t);
    }
  }
  final atStart = <String>[];
  final afterSpace = <String>[];
  for (var i = 0; i < tlds.idn.length; i++) {
    final t = tlds.idn[i];
    final at = 2 * all.length + 2 * i;
    final length = 'ops@example.$t'.length;
    if (linksWhole(readings[at], 0, length, 'email')) atStart.add(t);
    if (linksWhole(readings[at + 1], 1, length, 'email')) afterSpace.add(t);
  }
  String set(List<String> s) {
    final ascii = s.where((t) => tlds.ascii.contains(t)).length;
    return '${s.length} ($ascii ASCII, ${s.length - ascii} IDN): ${s.join(' ')}';
  }

  return [
    ...report,
    "TLDs of a linked 'see bücher.<tld> x': ${set(bare)}",
    "TLDs of a linked 'see www.bücher.<tld> x': ${set(www)}",
    "Unicode TLDs of an email 'ops@example.<tld>' at the text's start: ${set(atStart)}",
    "Unicode TLDs of an email ' ops@example.<tld>' after a space: ${set(afterSpace)}",
  ];
}
