import 'dart:convert';
import 'dart:io';

import 'corpus.dart';
import 'harness.dart';
import 'intree.dart';
import 'rules.dart';
import 'stages.dart';
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

  /// Whether the set holds [c].
  bool contains(int c) {
    var lo = 0;
    var hi = ranges.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (ranges[mid].$2 < c) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo < ranges.length && ranges[lo].$1 <= c;
  }

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

/// The character classes of Unicode 17.0.0 and of macOS 26.4 the oracle
/// compares.
class CharacterClasses {
  CharacterClasses._(this._unicode, this._mac);

  /// Unicode 17.0.0's classes from tool/url_data, and macOS's from the probe
  /// of [harness].
  static Future<CharacterClasses> read(Harness harness) async {
    final data = '${harness.host.uxRoot}/tool/url_data/unicode-17.0.0';
    final categories = readCategories(
      File('$data/DerivedGeneralCategory.txt').readAsStringSync(),
    );
    CodePoints category(List<String> names) =>
        CodePoints.of([for (final n in names) ...?categories[n]]);
    final alphabetic = property(
      File('$data/DerivedCoreProperties.txt').readAsStringSync(),
      'Alphabetic',
    );
    final marks = category(['Mn', 'Mc', 'Me']);
    final nd = category(['Nd']);
    final out = File('${harness.commitDir.path}/props.json');
    await run(await harness.probe(), ['props', out.path]);
    final mac = jsonDecode(out.readAsStringSync()) as Map<String, Object?>;
    CodePoints macSet(String name) => CodePoints.of([
      for (final r in (mac[name]! as List<Object?>).cast<List<Object?>>())
        (r[0]! as int, r[1]! as int),
    ]);
    return CharacterClasses._(
      {
        'L': category(['Lu', 'Ll', 'Lt', 'Lm', 'Lo']),
        'M': marks,
        'Nd': nd,
        'Cf': category(['Cf']),
        'S': category(['So', 'Sk']),
        'word':
            alphabetic |
            marks |
            nd |
            category(['Pc']) |
            CodePoints.of([(0x200C, 0x200D)]),
        'space':
            category(['Zs', 'Zl', 'Zp']) |
            CodePoints.of([(0x09, 0x0A), (0x0C, 0x0D)]),
      },
      {
        for (final name in ['letter', 'digit', 'word', 'space'])
          name: macSet(name),
      },
    );
  }

  final Map<String, CodePoints> _unicode;
  final Map<String, CodePoints> _mac;

  /// Unicode 17.0.0's general category L.
  CodePoints get letters => _unicode['L']!;

  /// Unicode 17.0.0's general category M.
  CodePoints get marks => _unicode['M']!;

  /// Unicode 17.0.0's general category Nd.
  CodePoints get digits => _unicode['Nd']!;

  /// Unicode 17.0.0's general category Cf.
  CodePoints get format => _unicode['Cf']!;

  /// Unicode 17.0.0's general categories So and Sk.
  CodePoints get symbols => _unicode['S']!;

  /// ICU's `\w` as Unicode 17.0.0 defines it: Alphabetic, M, Nd, Pc, U+200C
  /// and U+200D.
  CodePoints get word => _unicode['word']!;

  /// ICU's `\s` as Unicode 17.0.0 defines it: `[\t\n\f\r\p{Z}]`.
  CodePoints get space => _unicode['space']!;

  /// macOS's NSCharacterSet.letterCharacterSet.
  CodePoints get macLetters => _mac['letter']!;

  /// macOS's NSCharacterSet.decimalDigitCharacterSet.
  CodePoints get macDigits => _mac['digit']!;

  /// macOS ICU's `\w`.
  CodePoints get macWord => _mac['word']!;

  /// macOS ICU's `\s`.
  CodePoints get macSpace => _mac['space']!;

  /// The pairs the props report compares: a Unicode 17.0.0 class and the
  /// macOS class that stands for it.
  List<(String, CodePoints, CodePoints)> get pairs => [
    ('L against letterCharacterSet without M', letters, macLetters - marks),
    ('Nd against decimalDigitCharacterSet', digits, macDigits),
    (r'Alphabetic+M+Nd+Pc+U+200C+U+200D against ICU \w', word, macWord),
    (r'[\t\n\f\r\p{Z}] against ICU \s', space, macSpace),
  ];

  /// [cp]'s Unicode 17.0.0 classes of [pairs], as a bit set.
  int unicodeClassesOf(int cp) => [
    for (final (i, (_, unicode, _)) in pairs.indexed)
      if (unicode.contains(cp)) 1 << i,
  ].fold(0, (a, b) => a | b);

  /// [cp]'s macOS classes of [pairs], as a bit set.
  int macClassesOf(int cp) => [
    for (final (i, (_, _, mac)) in pairs.indexed)
      if (mac.contains(cp)) 1 << i,
  ].fold(0, (a, b) => a | b);

  /// Every code point where a pair of [pairs] differs.
  CodePoints get differences =>
      [for (final (_, unicode, mac) in pairs) (unicode - mac) | (mac - unicode)]
          .reduce((a, b) => a | b);
}

/// The TLDs NSDataDetector links on, from the probe's reading of every
/// kTlds entry and kIdnTlds label as written in src/tld.h: [bare] in
/// `see bücher.<tld> x`, [www] in `see www.bücher.<tld> x`, and an email's
/// Unicode TLDs in `ops@example.<tld>` at the text's start and after a space.
typedef NsddTlds = ({
  List<String> bare,
  List<String> www,
  List<String> emailAtStart,
  List<String> emailAfterSpace,
});

/// NSDataDetector's TLD sets at [harness]'s commit.
Future<NsddTlds> nsddTlds(Harness harness) async {
  final tlds = readTlds(await harness.host.show(harness.commit, 'src/tld.h'));
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
  return (
    bare: bare,
    www: www,
    emailAtStart: atStart,
    emailAfterSpace: afterSpace,
  );
}

/// The positions [conversions] reads a character in, by the kind of link
/// that holds it there; `$` stands for the character.
const conversionShapes = {
  'web': [
    'see https://exam\$ple.com x',
    'see https://example.com/a\$b x',
    'see example.com/a\$b x',
    'see https://example.com\$ x',
    'see example.com/a\$ x',
    'see tg://a/b\$c x',
    'https://\$docs.flutter.dev',
    'see https://example.com/?a=\$b x',
    'see www.exam\$ple.com/x y',
    'see https://example.com/\u0627\$\u0628 x',
    'see https://\u0915\u094D\$\u0937.com x',
  ],
  'local part': ['mail o\$ps@example.com now', 'mail ops\$@example.com now'],
  'domain': ['mail ops@exam\$ple.com now'],
  'phone': ['call +1 555\$123 4567 now'],
};

/// The Default_Ignorable code points and U+1680 a darwin link holds in its
/// text and leaves out of its URL, by the kind of position of
/// [conversionShapes]: its URL is the URL of the text without the character.
Future<Map<String, CodePoints>> conversions(Harness harness) async {
  final universe =
      property(
        File(
          '${harness.host.uxRoot}/tool/url_data/unicode-17.0.0/DerivedCoreProperties.txt',
        ).readAsStringSync(),
        'Default_Ignorable_Code_Point',
      ) |
      CodePoints.of([(0x1680, 0x1680)]);
  final points = [
    for (final (first, last) in universe.ranges)
      for (var cp = first; cp <= last; cp++) cp,
  ];
  final shapes = [
    for (final MapEntry(key: kind, value: list) in conversionShapes.entries)
      for (final shape in list) (kind, shape),
  ];
  final texts = [
    for (final (_, shape) in shapes) ...[
      shape.replaceFirst(r'$', ''),
      for (final cp in points)
        shape.replaceFirst(r'$', String.fromCharCode(cp)),
    ],
  ];
  final readings = await harness.read(texts, locale: 'en_US');
  final found = <String, List<(int, int)>>{};
  var at = 0;
  for (final (kind, shape) in shapes) {
    final position = shape.indexOf(r'$');
    final without = darwinMatch(texts[at], readings[at].native);
    at++;
    for (final cp in points) {
      final links = darwinMatch(texts[at], readings[at].native);
      at++;
      final converted = links.any(
        (l) =>
            l.start <= position &&
            position < l.end &&
            without.any((w) => w.start == l.start && w.url == l.url),
      );
      if (converted) (found[kind] ??= []).add((cp, cp));
    }
  }
  return {
    for (final kind in conversionShapes.keys)
      kind: CodePoints.of(found[kind] ?? const []),
  };
}

/// The props report: where macOS's character classes differ from Unicode
/// 17.0.0's, the TLDs NSDataDetector links a host or an email on, and the
/// invisible characters darwin's links convert beside a3's.
Future<List<String>> props(Harness harness) async {
  final host = harness.host;
  final classes = await CharacterClasses.read(harness);
  final report = <String>[];
  for (final (name, unicode, macOS) in classes.pairs) {
    final onlyUnicode = unicode - macOS;
    final onlyMac = macOS - unicode;
    report
      ..add('$name: ${onlyUnicode.length} only in Unicode 17.0.0: $onlyUnicode')
      ..add('$name: ${onlyMac.length} only on macOS: $onlyMac');
  }
  report.add(
    'letterCharacterSet holds '
    '${(classes.macLetters - classes.letters).length} code points outside L, '
    '${(classes.macLetters - classes.letters - classes.marks).length} of them '
    'outside M',
  );

  final tlds = readTlds(await host.show(harness.commit, 'src/tld.h'));
  final nsdd = await nsddTlds(harness);
  String set(List<String> s) {
    final ascii = s.where((t) => tlds.ascii.contains(t)).length;
    return '${s.length} ($ascii ASCII, ${s.length - ascii} IDN): ${s.join(' ')}';
  }

  final converted = await conversions(harness);
  return [
    ...report,
    for (final MapEntry(key: kind, value: points) in converted.entries)
      'Default_Ignorable code points and U+1680 a darwin link holds in a '
          '$kind and leaves out of its URL: ${points.length}: $points',
    "a3's invisible spaces: $invisibleSpaces; in an address's domain: "
        '$domainInvisibleSpaces',
    "TLDs of a linked 'see bücher.<tld> x': ${set(nsdd.bare)}",
    "TLDs of a linked 'see www.bücher.<tld> x': ${set(nsdd.www)}",
    "Unicode TLDs of an email 'ops@example.<tld>' at the text's start: ${set(nsdd.emailAtStart)}",
    "Unicode TLDs of an email ' ops@example.<tld>' after a space: ${set(nsdd.emailAfterSpace)}",
  ];
}
