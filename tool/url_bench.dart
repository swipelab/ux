// Times detectLinks over two windows of 10,000 chat messages, the chat mix
// and the short mix, and over adversarial families at 1,024 and 4,096 UTF-16
// units.
//
//   dart compile exe tool/url_bench.dart -o build/url_bench && build/url_bench [--linear]
//
// A window's time is the median of 21 reads after 5 warm-ups. A family's time
// at a size is the median of 9 samples after 3 warm-ups, each sample a batch
// of reads of about 2 ms divided by its reads, and its 4,096/1,024 ratio the
// median of the 9 ratios of a 4,096-unit sample to the 1,024-unit sample
// taken just before it. It exits 0 where every family's 4,096/1,024 ratio is
// at most 4.5 and its 4,096-unit time at most 2.5 ms, and, with no flag, each
// window reads in at most 10.0 ms.
import 'dart:io';

import 'package:ux/src/url/detect.dart';

import 'url_window.dart';

void main(List<String> args) {
  final linear = args.contains('--linear');
  var ok = true;
  stdout.writeln('window: 10,000 messages, seed 3451, median of 21 reads');
  for (final (name, mix) in [('chat', chatMix), ('short', shortMix)]) {
    final messages = window(mix);
    final total = _windowTime(messages.map((m) => m.text).toList());
    final units = messages.fold(0, (n, m) => n + m.text.length);
    final lengths = [for (final m in messages) m.text.length]..sort();
    stdout.writeln(
      '$name: ${_ms(total.median)} ms (21 reads ${_ms(total.min)}-'
      '${_ms(total.max)} ms), $units units, mean '
      '${(units / messages.length).toStringAsFixed(1)}, median '
      '${lengths[lengths.length ~/ 2]}',
    );
    for (final kind in MessageKind.values) {
      final texts = [
        for (final m in messages)
          if (m.kind == kind) m.text,
      ];
      if (texts.isEmpty) continue;
      final time = _windowTime(texts);
      stdout.writeln(
        '  ${kind.name.padRight(14)} ${texts.length.toString().padLeft(5)} '
        'messages ${_ms(time.median)} ms, '
        '${(time.median * 1e6 / texts.length).toStringAsFixed(0)} ns a message',
      );
    }
    if (!linear && total.median > 10.0) ok = false;
  }
  final ratioLimit = 4.5;
  final timeLimit = 2.5;
  stdout.writeln(
    '${'family'.padRight(40)} ${'1k us'.padLeft(9)} ${'4k us'.padLeft(9)} '
    '${'ratio'.padLeft(6)}',
  );
  for (final (name, prefix, unit) in _families) {
    final (:small, :large, :ratio) = _familyTimes(
      _text(prefix, unit, 1024),
      _text(prefix, unit, 4096),
    );
    final pass = ratio <= ratioLimit && large <= timeLimit;
    ok = ok && pass;
    stdout.writeln(
      '${name.padRight(40)} ${(small * 1000).toStringAsFixed(2).padLeft(9)} '
      '${(large * 1000).toStringAsFixed(2).padLeft(9)} '
      '${ratio.toStringAsFixed(2).padLeft(6)}${pass ? '' : '  FAIL'}',
    );
  }
  exit(ok ? 0 : 1);
}

String _ms(double ms) => ms.toStringAsFixed(3);

double _elapsedMs(Stopwatch watch) =>
    watch.elapsedTicks * 1000 / watch.frequency;

/// The median, least and greatest of 21 reads of [texts] after 5 warm-ups,
/// in ms.
({double median, double min, double max}) _windowTime(List<String> texts) {
  void read() {
    for (final t in texts) {
      detectLinks(t);
    }
  }

  for (var i = 0; i < 5; i++) {
    read();
  }
  final times = <double>[];
  for (var i = 0; i < 21; i++) {
    final watch = Stopwatch()..start();
    read();
    times.add(_elapsedMs(watch));
  }
  times.sort();
  return (median: times[10], min: times.first, max: times.last);
}

/// The ms a read of [small] and of [large] take, each the median of 9
/// batches of reads lasting at least 2 ms after 3 warm-up batches, and the
/// median of the 9 ratios of a large batch to the small batch read just
/// before it.
({double small, double large, double ratio}) _familyTimes(
  String small,
  String large,
) {
  final smallBatch = _batch(small);
  final largeBatch = _batch(large);
  for (var i = 0; i < 3; i++) {
    smallBatch();
    largeBatch();
  }
  final smalls = <double>[];
  final larges = <double>[];
  final ratios = <double>[];
  for (var i = 0; i < 9; i++) {
    smalls.add(smallBatch());
    larges.add(largeBatch());
    ratios.add(larges.last / smalls.last);
  }
  double median(List<double> values) => (values..sort())[values.length ~/ 2];
  return (small: median(smalls), large: median(larges), ratio: median(ratios));
}

/// A batch of reads of [text] lasting about 2 ms, giving its ms a read; each
/// batch sizes the next.
double Function() _batch(String text) {
  final once = Stopwatch()..start();
  detectLinks(text);
  final first = _elapsedMs(once);
  var reads = first <= 0 ? 1000 : (2 / first).ceil();
  return () {
    final watch = Stopwatch()..start();
    for (var i = 0; i < reads; i++) {
      detectLinks(text);
    }
    final perRead = _elapsedMs(watch) / reads;
    if (perRead > 0) reads = (2 / perRead).ceil().clamp(1, 1 << 20);
    return perRead;
  };
}

String _text(String prefix, String unit, int length) {
  final out = StringBuffer(prefix);
  while (out.length < length) {
    out.write(unit);
  }
  return out.toString().substring(0, length);
}

/// Each family: its name, the text before the repeated unit, and the unit.
const _families = [
  ("'x://' runs", '', 'x://'),
  ("'a-' runs after https://", 'https://', 'a-'),
  ("'a.' runs after https://", 'https://', 'a.'),
  ("'%2' runs after https://", 'https://', '%2'),
  ("'(' runs after https://", 'https://', '('),
  ("'(' runs in a path", 'https://example.com/', '('),
  ('a URL', 'https://example.com/', 'a'),
  ("userinfo with no '@'", 'https://', 'a:'),
  ("'a@' runs after https://", 'https://', 'a@'),
  ("'a-' runs", '', 'a-'),
  ("'a.' runs", '', 'a.'),
  ("'%2' runs", '', '%2'),
  ("'(' runs", '', '('),
  ("'a@' runs", '', 'a@'),
  (
    "'Is it really https://example.com!? '",
    '',
    'Is it really https://example.com!? ',
  ),
  (
    "'(https://docs.flutter.dev/setup)? ok '",
    '',
    '(https://docs.flutter.dev/setup)? ok ',
  ),
  ("'https://a.com/a\u00BB '", '', 'https://a.com/a\u00BB '),
  ("'http://a.com\u7136 '", '', 'http://a.com\u7136 '),
  ("'https://a.com,b.com '", '', 'https://a.com,b.com '),
  ("'https://a.com!?'", '', 'https://a.com!?'),
  ("'https://a.com,'", '', 'https://a.com,'),
  ("'(https://a.com/x)?'", '', '(https://a.com/x)?'),
  ("'https://a.com/a\u00BB'", '', 'https://a.com/a\u00BB'),
  ("'https://a.com!?x{'", '', 'https://a.com!?x{'),
  ("'https://a.com!?x\"'", '', 'https://a.com!?x"'),
  ("'bl://x!?'", '', 'bl://x!?'),
  (
    "'https://a.com(x)b\u00FCcher.de/x, '",
    '',
    'https://a.com(x)b\u00FCcher.de/x, ',
  ),
  (
    "'https://a.com(x)b\u00FCcher.de/x,'",
    '',
    'https://a.com(x)b\u00FCcher.de/x,',
  ),
  ("'https://a.com(x))?x '", '', 'https://a.com(x))?x '),
  ("'https://a.com(x))?x'", '', 'https://a.com(x))?x'),
  ("'http://example.com\u7136\u540E '", '', 'http://example.com\u7136\u540E '),
  ("'http://example.com\u7136\u540E'", '', 'http://example.com\u7136\u540E'),
  (
    "'y call +40 712 345 678 now and more words '",
    '',
    'y call +40 712 345 678 now and more words ',
  ),
  (
    "'y call +40 712 345 678 now and more words'",
    '',
    'y call +40 712 345 678 now and more words',
  ),
  (
    "'https://a.com(x)/http://[::1]:80/a\uFF1A!. '",
    '',
    'https://a.com(x)/http://[::1]:80/a\uFF1A!. ',
  ),
  (
    "'https://a.com(x)/http://[::1]:80/a\uFF1A!.'",
    '',
    'https://a.com(x)/http://[::1]:80/a\uFF1A!.',
  ),
  (
    "'\u0E02\u0E49\u0E2D\u0E21\u0E39\u0E25\u206C192.168.1.1/x\u7136\u200F\u540E '",
    '',
    '\u0E02\u0E49\u0E2D\u0E21\u0E39\u0E25\u206C192.168.1.1/x\u7136\u200F\u540E ',
  ),
  (
    "'\u0E02\u0E49\u0E2D\u0E21\u0E39\u0E25\u206C192.168.1.1/x\u7136\u200F\u540E'",
    '',
    '\u0E02\u0E49\u0E2D\u0E21\u0E39\u0E25\u206C192.168.1.1/x\u7136\u200F\u540E',
  ),
  ("'tel:+1 '", '', 'tel:+1 '),
  ("'tel:1'", '', 'tel:1'),
  ("'see tel:+15551234567 x '", '', 'see tel:+15551234567 x '),
  ("'tel:+1'", '', 'tel:+1'),
  ("'\u00E9.app '", '', '\u00E9.app '),
  ("'\u00E9.app'", '', '\u00E9.app'),
  ("'\u00E9' then '.app' runs", '\u00E9', '.app'),
  ("'a.com.\u0301 '", '', 'a.com.\u0301 '),
  ("'a.com.\u0301'", '', 'a.com.\u0301'),
  ("'\u0E02\u200Ba.com '", '', '\u0E02\u200Ba.com '),
  ("'\u0E02\u200Ba.com'", '', '\u0E02\u200Ba.com'),
  ("'\u0E02\u200Ba.com/'", '', '\u0E02\u200Ba.com/'),
  ("'webcal://a.\u0661 '", '', 'webcal://a.\u0661 '),
  ("'webcal://a.\u0661'", '', 'webcal://a.\u0661'),
  ("'https://a.com/x '", '', 'https://a.com/x '),
  ("'https://a.com/a\uFF08 '", '', 'https://a.com/a\uFF08 '),
  ("'https://a.com/a\uFF08'", '', 'https://a.com/a\uFF08'),
  ("a cut then 'b.co/x '", 'https://a.com/a\uFF081\uFF09/', 'b.co/x '),
  ("a cut then 'b.co/x'", 'https://a.com/a\uFF081\uFF09/', 'b.co/x'),
  ("'a.com/x '", '', 'a.com/x '),
  (
    "'see https://exam\u200Bple.com x '",
    '',
    'see https://exam\u200Bple.com x ',
  ),
  ("'see https://exam\u200Bple.com x'", '', 'see https://exam\u200Bple.com x'),
  ("'ops@exam\u3164ple.com '", '', 'ops@exam\u3164ple.com '),
  ("'ops@exam\u3164ple.com'", '', 'ops@exam\u3164ple.com'),
  (
    "'\u8BBF\u95EEexample.com\u7136\u540E'",
    '',
    '\u8BBF\u95EEexample.com\u7136\u540E',
  ),
  (
    "'\u043F\u0440\u0438\u043C\u0435\u0440.\u0440\u0444/x '",
    '',
    '\u043F\u0440\u0438\u043C\u0435\u0440.\u0440\u0444/x ',
  ),
  (
    "'\u043F\u0440\u0438\u043C\u0435\u0440.\u0440\u0444/x'",
    '',
    '\u043F\u0440\u0438\u043C\u0435\u0440.\u0440\u0444/x',
  ),
  ("'\u4E2D.' runs", '', '\u4E2D.'),
  ("'1.' runs", '', '1.'),
  ("'1-' runs", '', '1-'),
  ("'0 ' runs", '', '0 '),
  ("'+1 555 123 4567 '", '', '+1 555 123 4567 '),
  ("'mailto:a@b.com?'", '', 'mailto:a@b.com?'),
];
