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
