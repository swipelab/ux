import 'dart:convert';

/// One corpus text and the family that generated it.
typedef CorpusText = ({String family, String text});

/// The inputs a corpus reads besides its seed.
class CorpusInputs {
  /// The catalog's texts, the in-tree tests' texts, the oracle commit's TLDs,
  /// a code point sample of each general category and the ranges of
  /// `props`' Unicode class.
  const CorpusInputs({
    required this.catalog,
    required this.inTree,
    required this.asciiTlds,
    required this.idnTlds,
    required this.categories,
    required this.unicode,
  });

  /// The texts test/url passes to expectLinks.
  final List<String> catalog;

  /// The texts the in-tree url tests read.
  final List<String> inTree;

  /// The ASCII entries of the commit's kTlds, lowercase.
  final List<String> asciiTlds;

  /// The Unicode labels of the commit's kIdnTlds.
  final List<String> idnTlds;

  /// The code point ranges of each Unicode 17.0.0 general category.
  final Map<String, List<(int, int)>> categories;

  /// The code point ranges where macOS 26.4's classes differ from Unicode
  /// 17.0.0's.
  final List<(int, int)> unicode;
}

/// The corpus of [seed]: the catalog's and the in-tree texts, then every
/// generated family, each text once, in the order first generated.
List<CorpusText> generateCorpus(int seed, CorpusInputs inputs) {
  final rng = _Rng(seed);
  final seen = <String>{};
  final corpus = <CorpusText>[];
  void add(String family, String text) {
    if (seen.add(text)) corpus.add((family: family, text: text));
  }

  for (final text in inputs.catalog) {
    add('catalog', text);
  }
  for (final text in inputs.inTree) {
    add('in-tree', text);
  }
  _marks(rng, add);
  _invisible(rng, add);
  _unspaced(add);
  _idn(rng, inputs, add);
  _ipPort(rng, add);
  _opaque(add);
  _continuation(add);
  _email(rng, inputs, add);
  _phone(rng, add);
  _glue(rng, inputs, add);
  _unicode(rng, inputs, add);
  _cap(add);
  while (corpus.length < 160000) {
    add('mixed', _mixed(rng));
  }
  return corpus;
}

/// [corpus] as JSON lines of `[family, text]`, the bytes two runs of one seed
/// share.
String encodeCorpus(List<CorpusText> corpus) {
  final out = StringBuffer();
  for (final c in corpus) {
    out.writeln(jsonEncode([c.family, c.text]));
  }
  return out.toString();
}

/// The code point ranges of each general category in [source], the text of
/// DerivedGeneralCategory.txt.
Map<String, List<(int, int)>> readCategories(String source) {
  final categories = <String, List<(int, int)>>{};
  final line = RegExp(
    r'^([0-9A-F]+)(?:\.\.([0-9A-F]+))?\s*;\s*(\w+)',
    multiLine: true,
  );
  for (final m in line.allMatches(source)) {
    final first = int.parse(m[1]!, radix: 16);
    final last = m[2] == null ? first : int.parse(m[2]!, radix: 16);
    (categories[m[3]!] ??= []).add((first, last));
  }
  return categories;
}

typedef _Add = void Function(String family, String text);

/// A 32-bit generator whose sequence depends only on its seed.
class _Rng {
  _Rng(int seed) : _state = seed & _mask;

  static const _mask = 0xFFFFFFFF;

  int _state;

  int next() {
    _state = (_state + 0x9E3779B9) & _mask;
    var z = _state;
    z = ((z ^ (z >> 16)) * 0x85EBCA6B) & _mask;
    z = ((z ^ (z >> 13)) * 0xC2B2AE35) & _mask;
    return z ^ (z >> 16);
  }

  int below(int n) => next() % n;

  T pick<T>(List<T> items) => items[below(items.length)];
}

const _shapes = [
  'https://example.com',
  'https://example.com/a',
  'https://example.com/a?b=1',
  'https://example.com#frag',
  'https://example.com/a_(b)',
  'http://10.0.0.5:8080',
  'https://example.com:443/x',
  'https://user:pass@example.com/x',
  'http://[::1]:80/a',
  'ftp://a.io/a#',
  'https://例子.com/路径',
  'https://docs.flutter.dev/setup',
  'https://a.com(x)',
  'bl://x/a_(b)',
  'tg://resolve?domain=abc',
  'banlu://chat/42',
  'webcal://example.com/cal.ics',
  'example.com',
  'example.com/a',
  'example.com/a?b=1',
  'www.example.com',
  'www.example.com/a#b',
  'example.org:8443/docs',
  'banlu.app',
  'sub.example.co.uk',
  'example.xn--p1ai',
  '10.0.0.1',
  '192.168.1.1/x',
  'ops@example.com',
  'first.last+tag@sub.example.co.uk',
  'mailto:ops@example.com',
  'sms:+15551234567',
  'tel:+15551234567',
  '+40 712 345 678',
  '(021) 555-0199',
  '0712345678',
  'пример.рф',
  'www.例子.com',
  'bücher.de/x',
];

const _prefixes = [
  '',
  'see ',
  '(',
  '[',
  '"',
  "'",
  '“',
  '«',
  '<',
  '_',
  '1',
  'x',
  'é',
  '-',
  '@',
  ':',
  '/',
  '#',
  '.',
  '1.',
  'a.',
  '访问',
  'ข้อมูล',
  '​',
  'see (',
  'call ',
  'mail ',
  '中文 ',
];

const _trailingMarks = [')', '?', ':', '.', ',', ';', '!', "'", '(', '#', '/'];

const _otherMarks = [
  '”',
  '’',
  '…',
  '……',
  '»',
  '–',
  '-',
  '*',
  '~',
  '😀',
  '€',
  '"',
  ']',
  '>',
  '}',
  '|',
  '。',
  '，',
  '）',
  '】',
];

const _tails = ['', ' x', 'x', ' 然后', '然后', '1', '\n'];

/// Link shapes × prefixes × trailing marks: every run of one to three of
/// `) ? : . , ; ! ' ( # /`, the quote, ellipsis and symbol marks, and the
/// pairs of the two.
void _marks(_Rng rng, _Add add) {
  final suffixes = <String>[
    for (final a in _trailingMarks) ...[
      a,
      for (final b in _trailingMarks) ...[
        '$a$b',
        for (final c in _trailingMarks) '$a$b$c',
      ],
    ],
    for (final o in _otherMarks) ...[
      o,
      for (final m in _trailingMarks) ...['$o$m', '$m$o'],
    ],
  ];
  for (final shape in _shapes) {
    for (final prefix in _prefixes) {
      for (var i = 0; i < 50; i++) {
        add('marks', '$prefix$shape${rng.pick(suffixes)}${rng.pick(_tails)}');
      }
    }
  }
}

const _invisibles = [
  0x200B,
  0x200C,
  0x200D,
  0x2060,
  0x2061,
  0x2062,
  0x2063,
  0x2064,
  0x2065,
  0x206A,
  0x206B,
  0x206C,
  0x206D,
  0x206E,
  0x206F,
  0xFEFF,
  0x00A0,
  0x00AD,
  0x1680,
  0x205F,
  0x2028,
  0x2029,
  0x3000,
  0x0085,
  0x115F,
  0x3164,
  0xFFA0,
  0x180E,
  0x034F,
  0xFE0F,
  0xE0100,
  0x061C,
  0x200E,
  0x200F,
  0x202A,
  0x202B,
  0x202C,
  0x202D,
  0x202E,
  0x2066,
  0x2067,
  0x2068,
  0x2069,
  0x0000,
  0x0001,
  0x0005,
  0x0009,
  0x000A,
  0x000D,
  0x001C,
  0x001D,
  0x001E,
  0x001F,
  0x007F,
  0x0080,
  0x009F,
];

const _openers = [0x2066, 0x2067, 0x2068, 0x202A, 0x202B, 0x202D, 0x202E];

/// Each invisible character, bidi control and Cc at three places in each
/// shape, isolates and embeddings around a shape's host and path, and two
/// such characters at random places.
void _invisible(_Rng rng, _Add add) {
  for (final shape in _shapes) {
    for (final c in _invisibles) {
      for (var i = 0; i < 3; i++) {
        add(
          'invisible',
          'see ${_insert(shape, rng.below(shape.length + 1), c)} x',
        );
      }
    }
    final slash = shape.indexOf('/', shape.indexOf('//') + 2);
    for (final opener in _openers) {
      final close = String.fromCharCode(opener >= 0x2066 ? 0x2069 : 0x202C);
      final open = String.fromCharCode(opener);
      add('invisible', 'see $open$shape$close x');
      if (slash > 0) {
        add(
          'invisible',
          'see ${shape.substring(0, slash + 1)}$open${shape.substring(slash + 1)}$close x',
        );
      }
    }
  }
  for (var i = 0; i < 4000; i++) {
    var text = '${rng.pick(_prefixes)}${rng.pick(_shapes)}${rng.pick(_tails)}';
    for (var n = 0; n < 2; n++) {
      text = _insert(text, rng.below(text.length + 1), rng.pick(_invisibles));
    }
    add('invisible', text);
  }
}

String _insert(String text, int at, int codePoint) =>
    '${text.substring(0, at)}${String.fromCharCode(codePoint)}${text.substring(at)}';

const _unspacedWords = [
  '访问',
  '然后',
  '请看',
  '例子',
  'ここ',
  'カタカナ',
  '한국어',
  '보기',
  'ข้อมูล',
  'ที่',
  'ຂໍ້ມູນ',
  'មើល',
  'ကြည့်',
  'ㄅㄆ',
];

const _unspacedShapes = [
  'example.com',
  'example.com/a',
  'example.com:8080',
  'example.com:8080abc',
  'banlu.app/x',
  'www.example.com',
  'api.example.com.mirror.dev/docs',
  '192.168.1.1',
  '10.0.0.1',
  'https://example.com',
  'https://example.com/a',
  'http://example.com:8080',
  'bl://x',
  'ops@example.com',
  'example.com@x.com',
  'example.xn--p1ai',
  'xn--fsqu00a.xn--fiqs8s',
  'x.ai',
  'example.com.Then',
  'example.ไทย',
];

/// Shapes glued to or beside Han, kana, Hangul, Thai, Lao, Khmer, Myanmar and
/// Bopomofo words, CJK punctuation and a zero-width space between them.
void _unspaced(_Add add) {
  for (final shape in _unspacedShapes) {
    for (final w in _unspacedWords) {
      for (final text in [
        '$w$shape',
        '$shape$w',
        '$w$shape$w',
        '$w $shape',
        '$shape.$w',
        '$w​$shape',
        '$w：$shape',
        '$shape。$w',
        '$shape，$w',
      ]) {
        add('unspaced', text);
      }
    }
  }
}

const _idnLabels = [
  'bücher',
  'é',
  'éa',
  'straße',
  'παράδειγμα',
  'пример',
  'օրինակ',
  'მაგალითი',
  'उदाहरण',
  '한국',
  '예시',
  'דוגמה',
  'مثال',
  '例子',
  '中文',
  'れい',
  'テスト',
  'ไทย',
  'ตัวอย่าง',
  'বাংলা',
  'உதாரணம்',
  'ምሳሌ',
  'උදාහරණ',
  'དཔེ',
  'ຕົວຢ່າງ',
  'ឧទាហរណ៍',
  'ဥပမာ',
  'ઉદાહરણ',
  'ఉదాహరణ',
  'ᏣᎳᎩ',
  'ܐܬܐ',
];

/// IDN labels of each script in eight host shapes, on a sample of thirty
/// ASCII TLDs and twenty Unicode TLDs.
void _idn(_Rng rng, CorpusInputs inputs, _Add add) {
  final tlds = <String>[
    for (final t in [
      'com',
      'org',
      'net',
      'app',
      'dev',
      'io',
      'xyz',
      'online',
      'museum',
      'de',
    ])
      t,
    for (var i = 0; i < 20; i++) rng.pick(inputs.asciiTlds),
    for (final t in ['рф', 'ไทย', '한국', '中国', 'ελ', 'みんな']) t,
    for (var i = 0; i < 14; i++) rng.pick(inputs.idnTlds),
  ];
  for (final label in _idnLabels) {
    for (final tld in tlds) {
      for (final host in [
        '$label.$tld',
        'www.$label.$tld',
        'example.$label.$tld',
        '$label.example.$tld',
        'www.example.$label.$tld',
        '$label-$label.$tld',
        'WWW.$label.$tld',
        'example.www.$label.$tld/x',
      ]) {
        add('idn', 'see $host x');
      }
    }
  }
}

const _octets = [
  '0',
  '1',
  '9',
  '10',
  '99',
  '100',
  '199',
  '200',
  '249',
  '250',
  '255',
  '256',
  '010',
  '001',
  '00',
  '1000',
];

const _ipv6 = [
  '::1',
  '2001:db8::1',
  'fe80::1%25en0',
  'v1.fe80::a+en1',
  '::',
  '2001:db8:0:0:0:0:2:1',
  '::ffff:10.0.0.1',
  'zz::1',
  '1::2::3',
];

const _portHosts = [
  'example.com',
  'http://example.com',
  '10.0.0.1',
  'https://a.com',
  'www.example.com',
];

const _ports = [
  '',
  '0',
  '8',
  '80',
  '8080',
  '65535',
  '65536',
  '123456',
  '１２',
  '８０',
  '٣',
  '8080٣',
  '٨٠',
  '80a',
  '8080abc',
  '8080.com',
];

const _userinfo = [
  'http://user@example.com',
  'http://user:pass@example.com/x',
  'https://a@b@c.com/x',
  'http://u:p@host:8080@b.com',
  'user:pass@example.com',
  'http://example.com:8080@evil.com/x',
  'http://%41@b.com',
  'http://例子@b.com',
  'http://a b@c.com',
];

/// Dotted numbers of three to five parts in ten contexts, IPv6 literals in
/// eight forms, ports of every digit shape after five hosts, and userinfo.
void _ipPort(_Rng rng, _Add add) {
  String dotted(int parts) =>
      [for (var i = 0; i < parts; i++) rng.pick(_octets)].join('.');
  final contexts = <String Function(String, String)>[
    (ip, _) => 'see $ip x',
    (ip, _) => 'ip $ip/x',
    (ip, _) => '$ip:8080',
    (ip, _) => 'abc$ip x',
    (ip, _) => '访问$ip然后',
    (ip, _) => 'see $ip. x',
    (ip, _) => 'see ${ip}abc x',
    (ip, _) => 'http://$ip/',
    (ip, _) => 'ip +1 $ip x',
    (ip, other) => '$ip $other',
  ];
  for (var i = 0; i < 2000; i++) {
    final parts = i < 1500 ? 4 : (i < 1700 ? 3 : 5);
    final ip = dotted(parts);
    for (var n = 0; n < 3; n++) {
      add('ip-port', rng.pick(contexts)(ip, dotted(4)));
    }
  }
  for (final v in _ipv6) {
    for (final form in [
      'http://[$v]',
      'http://[$v]:80',
      'http://[$v]/a',
      'http://user@[$v]/',
      'http://[$v]:80@b',
      '[$v]',
      v,
      'http://[$v]:80/:',
    ]) {
      add('ip-port', 'see $form x');
      add('ip-port', form);
    }
  }
  for (final host in _portHosts) {
    for (final port in _ports) {
      for (final follower in [
        '',
        ' x',
        '/x',
        'abc',
        '然后',
        'ข้อมูล',
        '.com/x',
        ':',
        '?',
        '@b',
      ]) {
        for (final prefix in ['see ', '访问', '_']) {
          add('ip-port', '$prefix$host:$port$follower');
        }
      }
    }
  }
  for (final u in _userinfo) {
    for (final prefix in ['see ', 'x_', '_', '']) {
      for (final suffix in ['', ' x', '_']) {
        add('ip-port', '$prefix$u$suffix');
      }
    }
  }
}

const _schemes = [
  'sms',
  'tel',
  'callto',
  'maps',
  'xmpp',
  'sip',
  'im',
  'aim',
  'jabber',
  'news',
  'cid',
  'feed',
  'itms',
  'skype',
  'webcal',
  'spotify',
  'geo',
  'magnet',
  'bitcoin',
  'about',
  'data',
  'javascript',
  'mailto',
  'facetime',
  'urn',
  'http',
  'https',
  'ftp',
  'x-sms',
  'SMS',
  'Tel',
];

const _bodies = [
  'abc',
  'abc1',
  'a.b',
  'a=b',
  'a?b',
  'a/b',
  '1',
  '12',
  '+1',
  '+15551234567',
  '+1-555-123-4567',
  'a@b',
  'a@b.com',
  'user@example.com',
  'x,y',
  'a-b',
  'a_b',
  '%41',
  'é',
  '//x',
  '?q=1',
  '',
  'a b',
  '例子',
  'a#b',
  '0712345678',
];

/// Opaque schemes × body classes × contexts, and `webcal://` and other
/// schemes over hosts that end in non-ASCII digits.
void _opaque(_Add add) {
  for (final scheme in _schemes) {
    for (final body in _bodies) {
      for (final text in [
        'see $scheme:$body now',
        '$scheme:$body',
        '_$scheme:$body',
        'call $scheme:$body now',
        'x$scheme:$body now',
        '1$scheme:$body',
      ]) {
        add('opaque', text);
      }
    }
  }
  for (final scheme in ['webcal', 'sms', 'tel', 'feed', 'http']) {
    for (final host in [
      '10.0.0.1',
      '+15551234567',
      '256.1.1.1',
      'a',
      'example.com',
      '1.2',
      'x1',
      'a-1',
      'ab-1',
      'a.b-1',
      'a_1',
    ]) {
      for (final digits in ['١٢', '١', '٣٤٥', '१२', '１２', '12']) {
        add('opaque', '$scheme://$host.$digits');
      }
    }
  }
}

/// Links whose text runs on past fullwidth parentheses and other CJK
/// punctuation into a continuation of every kind and of the any-scheme pass.
void _continuation(_Add add) {
  const bases = [
    'https://example.com/a',
    'https://example.com/路径',
    'https://example.com#a',
    'https://example.com/a?q=1',
    'https://example.com',
    'example.com/a',
    'tg://x/a',
  ];
  const separators = ['（1）', '）', '（', '，', '。', '（1）。', '（x）', '、'];
  const delimiters = [
    '/',
    '?',
    '#',
    '&',
    '=',
    '',
    ' ',
    '/x/',
    '?m=',
    '#t=',
    '和/或',
    '例如a/b,',
  ];
  const continuations = [
    'page.com',
    'page.html',
    'www.example.org/x',
    'example.org',
    'a@b.com',
    '+1-555-123-4567',
    '10.0.0.1',
    'tg://a.io',
    'http://evil.com',
    'bl://chat/1',
    'mailto:a@b.com',
  ];
  for (final base in bases) {
    for (final separator in separators) {
      for (final delimiter in delimiters) {
        for (final continuation in continuations) {
          add('continuation', '$base$separator$delimiter$continuation');
        }
      }
    }
  }
}

const _locals = [
  'ops',
  'a',
  'first.last+tag',
  'a..b',
  '.a',
  'a.',
  'a!b#c',
  "o'neil",
  'a%b',
  'a|b',
  'a-b',
  'a_b',
  '_ops',
  '1ops',
  'josé',
  'José',
  '用户',
  '请联系ops',
  '٣한국b',
  'Ωmega',
  'пользователь',
  'ñ',
  'á',
  'a+b',
  'a=b',
  'a?b',
  'a{b}',
  'a~b',
  'a/b',
  'a`b',
  'a^b',
  '"a b"',
  'a\$b',
  'a&b',
  'a*b',
  'Ops.José',
  'a·b',
  'a–b',
  'ﬁ',
  'ㄅ',
  'ไทย',
  'ຂໍ້',
  '١٢٣',
  '１２３',
  'ａｂｃ',
];

const _domains = [
  'example.com',
  'sub.example.co.uk',
  'EXAMPLE.COM',
  'Example.APP',
  'example.zzz',
  'b.c',
  'b.co',
  'localhost',
  'example..com',
  '-example.com',
  '@example.com',
  '10.0.0.1',
  '[10.0.0.1]',
  '例子.com',
  '例子.COM',
  'Bücher.de',
  'ﬁx.com',
  'straße.de',
  'xn--bcher-kva.de',
  'xn--fsqu00a.xn--fiqs8s',
  'example.xn--p1ai',
  'example.com.Then',
  'example.com.',
  'exa_mple.com',
  'example.中国',
  'example.한국',
  'example.рф',
  'example.みんな',
  'example.公司',
  'example.例子',
  'example.пример',
  'example.c',
  'example.museum',
  '例子.中国',
];

const _linePositions = [
  r'$',
  r'$ now',
  r'mail $ now',
  '\n\$',
  '\r\$',
  '\r\n\$',
  ' \$',
  ' \$',
  r' $',
  'x\n\$ now',
  '\t\$',
  '　\$',
  r'请联系$',
  r'_$',
  r'($)',
  r'<$>',
  r'$, then',
  r'$. Then',
  r'mailto:$',
];

const _addressShapes = [
  '.a@example.com',
  'a.@example.com',
  'a..@example.com',
  '.@example.com',
  'a@b.xn--p1ai',
  'ops@xn--fsqu00a.xn--fiqs8s',
  'a|b@x.com',
  'a-b@example.com',
  '-a@example.com',
  'a&b@x.com',
  'banlu.app@x.com',
  '@banlu.app@x.com',
  'example.com@x.com',
  'ຂໍ້ມູນexample.com@x.com',
  'a@b@c.com',
  'a%b@x.com',
  '+a@x.com',
  'a@x-.com',
  'a@-x.com',
  'a@x.c-m',
];

/// Local parts by category and script × domain shapes × line positions, each
/// Unicode TLD as an address's last label in six positions, and
/// EMAIL_ADDRESS's edge shapes.
void _email(_Rng rng, CorpusInputs inputs, _Add add) {
  for (final local in _locals) {
    for (final domain in _domains) {
      for (var i = 0; i < 4; i++) {
        add(
          'email',
          rng.pick(_linePositions).replaceFirst(r'$', '$local@$domain'),
        );
      }
    }
  }
  for (final tld in inputs.idnTlds) {
    for (final position in [
      r'$',
      r'$ now',
      r'mail $ now',
      '\n\$',
      r' $',
      '\r\$',
    ]) {
      add('email', position.replaceFirst(r'$', 'ops@example.$tld'));
    }
  }
  final long = [
    'a@x.${'b' * 26}',
    'a@${'b' * 65}.com',
    '${'x' * 256}@x.com',
    '${'x' * 257}@x.com',
  ];
  for (final address in [..._addressShapes, ...long]) {
    for (final position in [r'$', r'mail $ now', r'see $', r'_$']) {
      add('email', position.replaceFirst(r'$', address));
    }
  }
}

const _countryCodes = [
  '',
  '+1 ',
  '+40 ',
  '+44 ',
  '+7 ',
  '+81 ',
  '+86 ',
  '+91 ',
  '+55 ',
  '+33 ',
  '+49 ',
  '+1-',
  '+40-',
  '+4',
  '(+40) ',
  '0040 ',
  '+',
];

const _trunks = ['', '0', '(0) ', '00', '1-', '8 '];

const _groups = [
  [3, 3, 4],
  [3, 3, 3],
  [2, 2, 2, 2, 2],
  [4, 3, 3],
  [4, 4],
  [3, 4],
  [6],
  [7],
  [8],
  [10],
  [11],
  [15],
  [20],
  [2, 4, 4],
  [3, 4, 4],
  [1, 3, 3, 4],
  [2, 8],
  [4, 6],
  [3, 2, 2, 3],
  [2, 3, 3, 2],
];

const _separators = [' ', '-', '.', '/', '', '  ', ' - '];

const _extensions = [
  '',
  ' ext. 89',
  ' x89',
  ' ext 5',
  ' #5',
  ';89',
  ',89',
  ' ext.89',
];

const _trailers = [
  '',
  'x',
  'a',
  '/9',
  '.',
  ',',
  ' or +40 712 345 679',
  ', 0712 345 679',
  '.5',
  ')',
  '-',
];

const _phoneContexts = [
  r'call $ now',
  r'$',
  r'tel $',
  r'a$ now',
  r'1$ now',
  r'-$ now',
  r'(at $)',
  r'call: $',
  'call \$ now',
  'call　\$ now',
  r'中文$',
  r'call $。',
  r'x 555 123 $ y',
];

/// Phone shapes from country codes, trunk prefixes, digit groups, separators,
/// a parenthesized first group, extensions, trailers and contexts, some in
/// fullwidth or Arabic-Indic digits, phones a later IPv4 address or domain
/// follows, and dotted numbers of four groups of two or three digits with
/// and without a phone word before them.
void _phone(_Rng rng, _Add add) {
  for (var i = 0; i < 25000; i++) {
    final groups = rng.pick(_groups);
    final separator = rng.pick(_separators);
    final parens = rng.below(4) == 0;
    final digits = rng.below(20) == 0
        ? (rng.below(2) == 0 ? 0xFF10 : 0x0660)
        : 0x30;
    final parts = [
      for (final length in groups)
        String.fromCharCodes([
          for (var d = 0; d < length; d++) digits + rng.below(10),
        ]),
    ];
    if (parens) parts[0] = '(${parts[0]})';
    final number =
        '${rng.pick(_countryCodes)}${rng.pick(_trunks)}${parts.join(separator)}'
        '${rng.pick(_extensions)}${rng.pick(_trailers)}';
    add('phone', rng.pick(_phoneContexts).replaceFirst(r'$', number));
  }
  for (final hidden in [
    '555 123 45.67.89.10',
    '555 123 example.com',
    '+1 555 10.0.0.1',
    '0712 345 678.example.com',
    '+40 712 345 678/a.com',
  ]) {
    for (final context in [r'x $ y', r'call $', r'$']) {
      add('phone', context.replaceFirst(r'$', hidden));
    }
  }
  for (final dotted in [
    '00.256.10.99',
    '01.256.10.98',
    '10.256.10.99',
    '00.25.10.99',
    '00.256.100.99',
    '00.256.10.999',
    '044.123.45.67',
  ]) {
    for (final context in [
      r'$',
      r' $',
      r'$ now',
      r'x $ now',
      r'see $ now',
      r'call $ now',
      r'访问$然后',
    ]) {
      add('phone', context.replaceFirst(r'$', dotted));
    }
  }
}

/// Each sampled code point of every general category after `example.com.`
/// in six contexts.
void _glue(_Rng rng, CorpusInputs inputs, _Add add) {
  final categories = inputs.categories.keys.toList()..sort();
  for (final category in categories) {
    final ranges = inputs.categories[category]!;
    for (var i = 0; i < 30; i++) {
      final (first, last) = rng.pick(ranges);
      final x = String.fromCharCode(first + rng.below(last - first + 1));
      for (final text in [
        'see example.com.$x x',
        'see example.com.${x}a x',
        '访问example.com.$x',
        'see www.example.com.$x x',
        'mail ops@example.com.$x now',
        'see example.com.$x',
      ]) {
        add('glue', text);
      }
    }
  }
}

/// One code point of each range of `props`' Unicode class after a port,
/// after and before a host, inside a word before a host, in a path, in a
/// local part and in a domain label.
void _unicode(_Rng rng, CorpusInputs inputs, _Add add) {
  for (final (first, last) in inputs.unicode) {
    final x = String.fromCharCode(first + rng.below(last - first + 1));
    for (final text in [
      'see example.com:80${x}x y',
      'see example.com:80$x y',
      'see example.com$x x',
      'see ${x}example.com x',
      'see a${x}example.com x',
      'see https://example.com/a${x}b x',
      'see example.com/a${x}b x',
      'mail o${x}ps@example.com now',
      'mail ops@exa${x}mple.com now',
      'see exa${x}mple.com x',
    ]) {
      add('unicode', text);
    }
  }
}

/// More than 64 links of each stage: NSDataDetector's, the second pass's,
/// the any-scheme pass's and a mix, with a link of another kind after them.
void _cap(_Add add) {
  for (final link in [
    'https://a.com',
    '10.0.0.1',
    'tg://a',
    'x.app',
    'https://a.com 10.0.0.1 tg://a',
  ]) {
    for (final count in [63, 64, 65, 66, 70, 130]) {
      for (final separator in [' ', ', ', '\n']) {
        for (final tail in [
          '',
          ' b.com',
          ' +40 712 345 678',
          ' ops@example.com',
        ]) {
          add('cap', '${List.filled(count, link).join(separator)}$tail');
        }
      }
    }
  }
}

/// Two to five shapes, words and marks with an invisible character at random.
String _mixed(_Rng rng) {
  const words = [
    'see',
    'call',
    'mail',
    '访问',
    '然后',
    'ข้อมูล',
    'x',
    '1',
    'and',
    'or',
  ];
  final out = StringBuffer();
  for (var n = 2 + rng.below(4); n > 0; n--) {
    switch (rng.below(4)) {
      case 0:
        out.write(rng.pick(words));
      case 1:
        out.write(rng.pick(_trailingMarks));
      default:
        out.write(rng.pick(_shapes));
    }
    out.write(rng.pick(const [' ', '', ', ', '. ', '\n', '/', '：']));
  }
  var text = out.toString();
  if (rng.below(3) == 0) {
    text = _insert(text, rng.below(text.length + 1), rng.pick(_invisibles));
  }
  return text;
}
