import 'wire.dart';

/// Raw NSDataDetector readings the planspec quotes: each text's result
/// spans.
const rawQuotes = <(String, List<(int, int)>)>[
  ('Is it really https://example.com!?', [(13, 34)]),
  ('see exam​ple.com x', [(9, 16)]),
  ('webcal://10.0.0.1.١٢', [(0, 8)]),
  ('1.2.3.4.5/x', []),
  ('see 1.2.3.4.5 x', []),
  ('see example.com.́ x', [(4, 15)]),
  ('see “https://example.com/a” x', [(5, 26)]),
  ('see https://example.com/a… x', [(4, 25)]),
  ('1.tg://a.io/a x', [(2, 13)]),
  ('ip 010.168.1.1 x', []),
  ('see www.bücher.zzz x', [(4, 18)]),
  ('(https://docs.flutter.dev/setup)?', [(1, 31)]),
  ('call ０７１２３４５６７８ now', [(5, 15)]),
  ('x 555 123 45.67.89.10 y', [(2, 21)]),
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
