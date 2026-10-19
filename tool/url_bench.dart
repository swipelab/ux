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

void main(List<String> args) {
  final linear = args.contains('--linear');
  var ok = true;
  stdout.writeln('window: 10,000 messages, seed 3451, median of 21 reads');
  for (final (name, mix) in [('chat', _chat), ('short', _short)]) {
    final window = _window(mix);
    final total = _windowTime(window.map((m) => m.text).toList());
    final units = window.fold(0, (n, m) => n + m.text.length);
    final lengths = [for (final m in window) m.text.length]..sort();
    stdout.writeln(
      '$name: ${_ms(total.median)} ms (21 reads ${_ms(total.min)}-'
      '${_ms(total.max)} ms), $units units, mean '
      '${(units / window.length).toStringAsFixed(1)}, median '
      '${lengths[lengths.length ~/ 2]}',
    );
    for (final kind in _Kind.values) {
      final texts = [
        for (final m in window)
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

/// What a window message holds.
enum _Kind { prose, falseTrigger, link, links, email, phone, long }

/// A share of a window's messages, in hundredths of a percent.
typedef _Mix = List<(_Kind, int)>;

const _Mix _chat = [
  (_Kind.prose, 8800),
  (_Kind.falseTrigger, 500),
  (_Kind.link, 400),
  (_Kind.links, 50),
  (_Kind.email, 50),
  (_Kind.phone, 100),
  (_Kind.long, 100),
];

const _Mix _short = [
  (_Kind.prose, 9160),
  (_Kind.falseTrigger, 400),
  (_Kind.link, 300),
  (_Kind.links, 30),
  (_Kind.email, 30),
  (_Kind.phone, 50),
  (_Kind.long, 30),
];

/// The prose lengths of each mix, in UTF-16 units: a share in hundredths of
/// a percent and a range.
const _chatLengths = [
  (5000, 2, 30),
  (3500, 30, 80),
  (1200, 80, 200),
  (300, 200, 600),
];

const _shortLengths = [
  (6000, 2, 25),
  (3000, 25, 60),
  (900, 60, 150),
  (100, 150, 400),
];

/// A 32-bit xorshift generator.
class _Rng {
  _Rng(this._state);

  int _state;

  int next() {
    var x = _state;
    x ^= (x << 13) & 0xFFFFFFFF;
    x ^= x >> 17;
    x ^= (x << 5) & 0xFFFFFFFF;
    return _state = x;
  }

  int below(int n) => next() % n;

  int between(int lo, int hi) => lo + below(hi - lo + 1);

  T pick<T>(List<T> items) => items[below(items.length)];
}

/// The 10,000 messages of [mix], from seed 3451.
List<({_Kind kind, String text})> _window(_Mix mix) {
  final rng = _Rng(3451);
  final lengths = identical(mix, _chat) ? _chatLengths : _shortLengths;
  return [
    for (var i = 0; i < 10000; i++) _message(rng, _share(rng, mix), lengths),
  ];
}

_Kind _share(_Rng rng, _Mix mix) {
  var at = rng.below(10000);
  for (final (kind, share) in mix) {
    if (at < share) return kind;
    at -= share;
  }
  return mix.last.$1;
}

({_Kind kind, String text}) _message(
  _Rng rng,
  _Kind kind,
  List<(int, int, int)> lengths,
) {
  int length() {
    var at = rng.below(10000);
    for (final (share, lo, hi) in lengths) {
      if (at < share) return rng.between(lo, hi);
      at -= share;
    }
    return rng.between(lengths.last.$2, lengths.last.$3);
  }

  final text = switch (kind) {
    _Kind.prose => _prose(rng, length()),
    _Kind.falseTrigger => _around(rng, rng.pick(_falseTriggers), length()),
    _Kind.link => _placed(rng, _link(rng), length()),
    _Kind.links => [
      for (var n = rng.between(2, 5); n > 0; n--) _placed(rng, _link(rng), 20),
    ].join(' '),
    _Kind.email => _around(rng, rng.pick(_emails), length()),
    _Kind.phone => _around(rng, rng.pick(_phones), length()),
    _Kind.long =>
      rng.below(2) == 0
          ? _prose(rng, rng.between(500, 2000))
          : _around(rng, _link(rng), rng.between(500, 2000)),
  };
  return (kind: kind, text: text);
}

/// Prose of about [length] units: 80% English, the rest in another
/// language, ending in '.', '!', '?', '...' or nothing, 15% with an emoji.
String _prose(_Rng rng, int length) {
  final words = rng.below(5) == 0 ? rng.pick(_otherWords) : _english;
  final spaced =
      !identical(words, _chinese) &&
      !identical(words, _japanese) &&
      !identical(words, _thai);
  final out = StringBuffer();
  var emoji = rng.below(100) < 15 ? rng.below(length + 1) : null;
  while (out.length < length) {
    if (out.isNotEmpty && spaced) out.write(' ');
    if (emoji != null && out.length >= emoji) {
      out.write(rng.pick(_emoji));
      if (spaced) out.write(' ');
      emoji = null;
    }
    out.write(rng.pick(words));
  }
  out.write(rng.pick(const ['.', '!', '?', '...', '', '']));
  return out.toString();
}

/// [item] inside prose of about [length] units.
String _around(_Rng rng, String item, int length) {
  final rest = length - item.length;
  if (rest <= 4) return item;
  final before = rng.below(rest);
  return '${before < 2 ? '' : '${_prose(rng, before)} '}$item'
      '${rest - before < 2 ? '' : ' ${_prose(rng, rest - before)}'}';
}

/// [link] alone, in parentheses, before '.', after ':' or inside prose.
String _placed(_Rng rng, String link, int length) => switch (rng.below(5)) {
  0 => link,
  1 => '${_prose(rng, 12)} ($link)',
  2 => '${_prose(rng, 16)} $link.',
  3 => 'here: $link',
  _ => _around(rng, link, length),
};

/// A link: 65% with a scheme, 35% a bare host.
String _link(_Rng rng) =>
    rng.below(100) < 65 ? rng.pick(_schemeLinks) : rng.pick(_bareHosts);

const _schemeLinks = [
  'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
  'https://youtu.be/dQw4w9WgXcQ',
  'https://github.com/flutter/flutter/issues/12345',
  'https://github.com/dart-lang/sdk/pull/5678/files',
  'https://docs.flutter.dev/get-started/install/macos',
  'https://api.dart.dev/stable/dart-core/String-class.html',
  'https://maps.google.com/?q=52.5200,13.4050',
  'https://goo.gl/maps/AbCdEfGh123',
  'https://t.me/banlu_chat',
  'https://www.amazon.com/dp/B08N5WRWNW?ref=ppx_yo_dt',
  'https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC',
  'https://zoom.us/j/91234567890?pwd=abcDEF123',
  'https://drive.google.com/file/d/1AbCdEfGhIjKlMn/view?usp=sharing',
  'https://en.wikipedia.org/wiki/Link_(The_Legend_of_Zelda)',
  'http://example.com/a/b?c=1&d=2#e',
];

const _bareHosts = [
  'example.com',
  'github.com/flutter',
  'google.com',
  'banlu.app',
  'news.ycombinator.com',
  'www.bbc.co.uk/news',
  'docs.google.com/document/d/1x',
  't.me/somechannel',
  'amazon.de',
  'reddit.com/r/FlutterDev',
];

const _falseTriggers = [
  'at 10:30',
  'about 3.5 hours',
  'for \$4.99',
  'on v2.1.3',
  'e.g. this',
  'i.e. that',
  'the U.S. office',
  'ok.thanks',
  'Note:check',
  'at 7.45pm',
  'score 2:1',
  '1.5x faster',
];

const _emails = [
  'ops@example.com',
  'jane.doe@gmail.com',
  'first.last+tag@sub.example.co.uk',
  'support@banlu.app',
];

const _phones = [
  '+40 712 345 678',
  '(555) 123-4567',
  '0712 345 678',
  '+1 555 123 4567',
  '+44 20 7946 0958',
];

const _emoji = [
  '\u{1F600}',
  '\u{1F44D}',
  '\u{1F389}',
  '\u2764\uFE0F',
  '\u{1F602}',
];

final _english =
    ('the and you that was for are with his they this have from one had word '
            'but not what all were when your can said there use each which she '
            'how their will other about out many then them these some her would '
            'make like him into time has look two more write see number way '
            'could people than first water been call who now find long down day '
            'did get come made may part ok yes sure thanks lol tomorrow later '
            'meeting dinner home work great sounds good love')
        .split(' ');

final _russian =
    'привет как дела хорошо спасибо завтра встреча дома работа да нет это'
        .split(' ');

final _spanish =
    'hola qué tal gracias mañana nos vemos casa trabajo sí bien está'.split(
      ' ',
    );

final _german =
    'hallo wie geht danke morgen treffen zuhause Arbeit ja nein schön Straße'
        .split(' ');

final _chinese = '你好 我们 明天 见面 谢谢 工作 回家 好的 没问题 今天'.split(' ');

final _japanese = 'こんにちは ありがとう 明日 会議 です ます 大丈夫 家に 帰る よろしく'.split(' ');

final _korean = '안녕하세요 감사합니다 내일 만나요 회의 집에 좋아요 네 아니요 오늘'.split(' ');

final _thai = 'สวัสดี ขอบคุณ พรุ่งนี้ ประชุม บ้าน ทำงาน ครับ ค่ะ ไม่ ใช่'.split(
  ' ',
);

final _arabic = 'مرحبا شكرا غدا اجتماع البيت العمل نعم لا جميل اليوم'.split(
  ' ',
);

final _otherWords = [
  _russian,
  _spanish,
  _german,
  _chinese,
  _japanese,
  _korean,
  _thai,
  _arabic,
];
