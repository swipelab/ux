import 'wire.dart';

/// Raw NSDataDetector readings the planspec quotes: each text's result
/// spans.
const rawQuotes = <(String, List<(int, int)>)>[
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

/// Each quote of [rawQuotes] that [raw] does not reproduce, with what it
/// reads.
List<String> rawMismatches(Map<String, List<RawResult>> raw) => [
  for (final (text, spans) in rawQuotes)
    if (!_spans(raw[text]!, spans)) '${printable(text)}: raw ${raw[text]}',
];

bool _spans(List<RawResult> raw, List<(int, int)> spans) =>
    raw.length == spans.length &&
    [
      for (var i = 0; i < raw.length; i++)
        raw[i].start == spans[i].$1 && raw[i].end == spans[i].$2,
    ].every((same) => same);

/// Synthetic detector defects, each beside the class whose predicate it
/// must stay out of: the class, a text, and the wrong Dart reading made
/// from the text's darwin reading.
final classMutations = <(String, String, List<Link> Function(List<Link>))>[
  ('question 6', 'see пример.рф x', (_) => const []),
  (
    'question 6',
    'see 例子.com x',
    (_) => const [Link(4, 10, 'web', 'http://例子.com')],
  ),
  (
    'question 6',
    'see www.example.ລາວ.com x',
    (_) => const [Link(4, 23, 'web', 'http://www.example.ລາວ.com')],
  ),
  (
    'question 6',
    'see пример.РФ x',
    (_) => const [Link(4, 13, 'web', 'http://пример.РФ')],
  ),
  (
    'b5',
    'see éxample.zzz x',
    (_) => const [Link(4, 15, 'web', 'http://éxample.zzz')],
  ),
  (
    'b4',
    'mail ops@example.com now',
    (_) => const [Link(5, 19, 'email', 'mailto:ops@example.co')],
  ),
  (
    'b4',
    'mail ops@EXAMPLE.COM now',
    (_) => const [Link(5, 20, 'email', 'mailto:ops@example.com')],
  ),
  (
    'b4',
    'see a|b@x.com',
    (_) => const [Link(6, 13, 'email', 'mailto:b@x.com')],
  ),
  (
    'question 3',
    'call +40 712 345 678 now',
    (_) => const [Link(5, 20, 'phone', 'tel:+4071234567')],
  ),
  (
    'question 3',
    'call +1 (555) 123-4567 ext. 89 now',
    (_) => const [Link(5, 30, 'phone', 'tel:+155512345')],
  ),
  (
    'b10',
    '"ftp://a.io/a#​ +15551234567',
    (darwin) => [const Link(1, 14, 'web', 'ftp://a.io/a#'), ...darwin.skip(1)],
  ),
  (
    'b10',
    'see https://example.com/a😀',
    (_) => const [Link(4, 25, 'web', 'https://example.com/a')],
  ),
  (
    'b10',
    'see example.zzz— x',
    (_) => const [Link(4, 15, 'web', 'http://example.zzz')],
  ),
  (
    'b11',
    'see example.zzz… x',
    (_) => const [Link(4, 15, 'web', 'http://example.zzz')],
  ),
  (
    'b12',
    'see example.com:８０ x',
    (_) => const [Link(4, 18, 'web', 'http://example.com:81')],
  ),
  (
    'b2',
    'https://example.com/a）/page.com',
    (darwin) => darwin.take(1).toList(),
  ),
  ('question 4', 'see https://a.com!b x', (_) => const []),
  (
    'question 4',
    'see https://a.com/b.com x',
    (darwin) => [...darwin, const Link(18, 23, 'web', 'http://b.com')],
  ),
];
