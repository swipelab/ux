// The windows of 10,000 chat messages that link detection is timed over: the
// chat mix and the short mix, from seed 3451.

/// What a window message holds.
enum MessageKind { prose, falseTrigger, link, links, email, phone, long }

/// A share of a window's messages, in hundredths of a percent.
typedef Mix = List<(MessageKind, int)>;

/// The chat mix.
const Mix chatMix = [
  (MessageKind.prose, 8800),
  (MessageKind.falseTrigger, 500),
  (MessageKind.link, 400),
  (MessageKind.links, 50),
  (MessageKind.email, 50),
  (MessageKind.phone, 100),
  (MessageKind.long, 100),
];

/// The short mix: shorter prose than [chatMix], with fewer links, emails and
/// phones.
const Mix shortMix = [
  (MessageKind.prose, 9160),
  (MessageKind.falseTrigger, 400),
  (MessageKind.link, 300),
  (MessageKind.links, 30),
  (MessageKind.email, 30),
  (MessageKind.phone, 50),
  (MessageKind.long, 30),
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
List<({MessageKind kind, String text})> window(Mix mix) {
  final rng = _Rng(3451);
  final lengths = identical(mix, chatMix) ? _chatLengths : _shortLengths;
  return [
    for (var i = 0; i < 10000; i++) _message(rng, _share(rng, mix), lengths),
  ];
}

MessageKind _share(_Rng rng, Mix mix) {
  var at = rng.below(10000);
  for (final (kind, share) in mix) {
    if (at < share) return kind;
    at -= share;
  }
  return mix.last.$1;
}

({MessageKind kind, String text}) _message(
  _Rng rng,
  MessageKind kind,
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
    MessageKind.prose => _prose(rng, length()),
    MessageKind.falseTrigger => _around(
      rng,
      rng.pick(_falseTriggers),
      length(),
    ),
    MessageKind.link => _placed(rng, _link(rng), length()),
    MessageKind.links => [
      for (var n = rng.between(2, 5); n > 0; n--) _placed(rng, _link(rng), 20),
    ].join(' '),
    MessageKind.email => _around(rng, rng.pick(_emails), length()),
    MessageKind.phone => _around(rng, rng.pick(_phones), length()),
    MessageKind.long =>
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
