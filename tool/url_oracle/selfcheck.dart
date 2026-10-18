import 'diff.dart';
import 'rules.dart';
import 'stages.dart';
import 'wire.dart';

/// Raw NSDataDetector readings the planspec quotes: each text's result
/// spans under the locales it quotes them in.
final rawQuotes = <(String, List<String>, List<(int, int)>)>[
  for (final (text, spans) in _enUsQuotes) (text, const ['en_US'], spans),
  ('00.256.10.99', _notJapanese, [(0, 12)]),
  ('00.256.10.99', const ['ja_JP'], []),
  ('x 00.256.10.99 now', _notJapanese, [(2, 14)]),
  ('x 00.256.10.99 now', const ['ja_JP'], []),
  ('see 00.256.10.99 now', _notJapanese, [(4, 16)]),
  ('see 00.256.10.99 now', const ['ja_JP'], []),
  ('call 00.256.10.99 now', quotedLocales, [(5, 17)]),
  ('00.25.10.99', quotedLocales, [(0, 11)]),
  ('00.256.100.99', quotedLocales, [(0, 13)]),
  ('00.256.10.999', quotedLocales, [(0, 13)]),
  ('044.123.45.67', quotedLocales, [(0, 13)]),
];

/// The locales the planspec quotes raw readings and the locale check in.
const quotedLocales = ['en_US', 'en_GB', 'de_DE', 'en_RO', 'ja_JP'];

const _notJapanese = ['en_US', 'en_GB', 'de_DE', 'en_RO'];

const _enUsQuotes = <(String, List<(int, int)>)>[
  ('Is it really https://example.com!?', [(13, 34)]),
  ('see exam​ple.com x', [(9, 16)]),
  ('webcal://10.0.0.1.١٢', [(0, 8)]),
  ('webcal://+15551234567.١٢', [(0, 8)]),
  ('webcal://256.1.1.1.١٢', [(0, 8)]),
  ('1.2.3.4.5/x', []),
  ('see 1.2.3.4.5 x', []),
  ('see example.com.́ x', [(4, 15)]),
  ('see “https://example.com/a” x', [(5, 26)]),
  ('see https://example.com/a… x', [(4, 25)]),
  ('1.tg://a.io/a x', [(2, 13)]),
  ('ip 010.168.1.1 x', []),
  ('see www.bücher.zzz x', [(4, 18)]),
  ('(https://docs.flutter.dev/setup)?', [(1, 31)]),
  ('x 555 123 45.67.89.10 y', [(2, 21)]),
  ('call 0712 345 678 now', [(5, 17)]),
  ('call 0712345678 now', [(5, 15)]),
  ('call +40 712 345 678 now', [(5, 20)]),
  ('call +40-712-345-678 now', [(5, 20)]),
  ('call +40.712.345.678 now', [(5, 20)]),
  ('call +40/712/345/678 now', [(5, 20)]),
  ('call (555) 123-4567 now', [(5, 19)]),
  ('call (021) 555-0199 now', [(5, 19)]),
  ('call (0) 712 345 678 now', [(5, 20)]),
  ('call +40 (0) 712 345 678 now', [(5, 24)]),
  ('call (+40) 712 345 678 now', [(5, 22)]),
  ('call 0040 712 345 678 now', [(5, 21)]),
  ('call 07 12 34 56 78 now', [(5, 19)]),
  ('call 0712 345 67 now', [(5, 16)]),
  ('call 030 123456 now', [(5, 15)]),
  ('call +44 20 7946 0958 now', [(5, 21)]),
  ('call +81 3-1234-5678 now', [(5, 20)]),
  ('call +7 (495) 123-45-67 now', [(5, 23)]),
  ('call +1 (555)123-4567 now', [(5, 21)]),
  ('call ０７１２３４５６７８ now', [(5, 15)]),
  ('call 0712.345.678 now', []),
  ('call 07123456 now', []),
  ('call 0123456 now', []),
  ('call 0712 345 now', []),
  ('call +4071234 now', []),
  ('call +40712345678901234 now', []),
  ('call 0 7 1 2 3 4 5 6 7 8 now', []),
  ('call 01234567890123456789 now', []),
  ('id 0123-4567-8901 now', []),
  ('call 0123-4567-8901 now', [(5, 19)]),
  ('see 0123-4567-8901 now', [(4, 18)]),
  ('call +40 712 345 678x now', [(5, 16)]),
  ('00.256.10.99', [(0, 12)]),
  ('call 00.256.10.99 now', [(5, 17)]),
  ('see a.com,b.com x', [(4, 9), (10, 15)]),
];

/// Each quote of [rawQuotes] that [raw], the readings by locale and text,
/// does not reproduce, with what it reads.
List<String> rawMismatches(Map<String, Map<String, List<RawResult>>> raw) => [
  for (final (text, locales, spans) in rawQuotes)
    for (final locale in locales)
      if (!_spans(raw[locale]![text]!, spans))
        '${printable(text)} under $locale: raw ${raw[locale]![text]}',
];

bool _spans(List<RawResult> raw, List<(int, int)> spans) =>
    raw.length == spans.length &&
    [
      for (var i = 0; i < raw.length; i++)
        raw[i].start == spans[i].$1 && raw[i].end == spans[i].$2,
    ].every((same) => same);

/// Whether [a] and [b] hold the same links in the same order.
bool sameLinks(List<Link> a, List<Link> b) =>
    a.length == b.length &&
    [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((same) => same);

/// Self-check 1: the texts whose probe-stages buffer differs from the
/// plain probe's, whose stage 3 over its candidates differs from that
/// buffer, and whose stages 4 to 7 over it differ from the replay's
/// XUrl.match [darwin], by check.
Map<String, List<String>> stageMismatches(
  List<String> texts,
  List<ProbeReading> plain,
  List<ProbeReading> staged,
  List<List<Link>> darwin,
) {
  final out = {
    'buffer': <String>[],
    'stage 3': <String>[],
    'stages 4-7': <String>[],
  };
  for (var i = 0; i < texts.length; i++) {
    final buffer = staged[i].native;
    if (!sameLinks(buffer, plain[i].native)) {
      out['buffer']!.add(printable(texts[i]));
    }
    final kept = stage3(texts[i], [
      for (final c in staged[i].candidates!) c.link,
    ]).kept;
    if (!sameLinks(kept, buffer)) out['stage 3']!.add(printable(texts[i]));
    if (!sameLinks(darwinMatch(texts[i], buffer), darwin[i])) {
      out['stages 4-7']!.add(printable(texts[i]));
    }
  }
  return out;
}

/// Self-check 5: each code point the Unicode stand-in replaces whose
/// representative's macOS classes differ from its Unicode 17.0.0 classes,
/// or that has none.
List<String> representativeMismatches(RuleData data) {
  final c = data.characters;
  final out = <String>[];
  for (final (first, last) in c.differences.ranges) {
    for (var cp = first; cp <= last; cp++) {
      final r = data.representative(cp);
      if (r == null || c.macClassesOf(r) != c.unicodeClassesOf(cp)) {
        out.add('${_hex(cp)}: representative ${r == null ? 'none' : _hex(r)}');
      }
    }
  }
  return out;
}

String _hex(int c) => 'U+${c.toRadixString(16).toUpperCase().padLeft(4, '0')}';

/// The count of each class among [classified], in the ledger's order.
List<String> classCounts(Iterable<Classified> classified) {
  final counts = <String, int>{};
  for (final c in classified) {
    counts[c.edit] = (counts[c.edit] ?? 0) + 1;
  }
  return [for (final (edit, name) in ledger) '  $name: ${counts[edit] ?? 0}'];
}
