@Skip('the Dart detector does not read bare hosts yet')
library;

import 'package:flutter_test/flutter_test.dart';

import 'links.dart';

void main() {
  test('a bare domain on a listed TLD links with no path', () {
    expectLinks('banlu.app', [web(0, 9, 'http://banlu.app')]);
    expectLinks('see sub.example.co.uk x', [
      web(4, 21, 'http://sub.example.co.uk'),
    ]);
  });

  test('a bare domain on an unlisted TLD does not link', () {
    expectLinks('see example.zzz x', const []);
    expectLinks('see localhost x', const []);
  });

  test(
    'a TLD matches in lowercase, or in any case for com, edu, gov, net and org',
    () {
      expectLinks('see Example.Com x', [web(4, 15, 'http://Example.Com')]);
      expectLinks('see EXAMPLE.APP x', const []);
      expectLinks('see Example.app x', [web(4, 15, 'http://Example.app')]);
      expectLinks('see пример.РФ x', const []);
      expectLinks('see EXAMPLE.рф x', [web(4, 14, 'http://EXAMPLE.рф')]);
    },
  );

  test('a punycode TLD links', () {
    expectLinks('see example.xn--p1ai x', [
      web(4, 20, 'http://example.xn--p1ai'),
    ]);
  });

  test("a punycode TLD ends before a '-' and the letters after it", () {
    expectLinks('example.xn--p1ai-é', [web(0, 16, 'http://example.xn--p1ai')]);
    expectLinks('xn--fsqu00a.xn--fiqs8s-然后', [
      web(0, 22, 'http://xn--fsqu00a.xn--fiqs8s'),
    ]);
    expectLinks('example.com-é', [web(0, 11, 'http://example.com')]);
  });

  test("a host's labels take '-' and '_' inside them", () {
    expectLinks('see ex-ample.com x', [web(4, 16, 'http://ex-ample.com')]);
    expectLinks('see ex_ample.com x', [web(4, 16, 'http://ex_ample.com')]);
    expectLinks('see example-.com x', const []);
    expectLinks('see -example.com x', [web(5, 16, 'http://example.com')]);
  });

  test("a host's ASCII letters match their case closure", () {
    expectLinks('see eKample.com x', [web(4, 15, 'http://eKample.com')]);
    expectLinks('see paſs.com x', [web(4, 12, 'http://paſs.com')]);
  });

  test('a letter a period glues to a bare domain makes it no link', () {
    expectLinks('see example.com.Then you', const []);
    expectLinks('see example.com.Über x', const []);
    expectLinks('see example.com.T x', const []);
    expectLinks('see example.com.a-b x', const []);
    expectLinks('see example.com.Then1 x', const []);
  });

  test('a letter a period glues to a www. host or a host with a path makes it no link', () {
    expectLinks('see www.example.com.Then you', const []);
    expectLinks('see example.com.Then/x you', const []);
  });

  test('a character after the period that is no letter links the host', () {
    expectLinks('see example.com.€a x', [web(4, 15, 'http://example.com')]);
    expectLinks('see example.com.١٢ x', [web(4, 15, 'http://example.com')]);
    expectLinks('see example.com.Ⅻ x', [web(4, 15, 'http://example.com')]);
    expectLinks('see example.com. Then', [web(4, 15, 'http://example.com')]);
  });

  test('an unspaced-script letter after the period links the host', () {
    expectLinks('see example.com.ที่ x', [web(4, 15, 'http://example.com')]);
  });

  test('a combining mark after the period links the host', () {
    expectLinks('see example.com.\u0301 x', [
      web(4, 15, 'http://example.com'),
    ], apple: const []);
  });

  test('a letter of Unicode 17.0.0 after the period makes it no link', () {
    expectLinks(
      'see example.com.\u{105C0} x',
      const [],
      apple: [web(4, 15, 'http://example.com')],
    );
  });

  test('a host with more labels links whole', () {
    expectLinks('访问 api.example.com.mirror.dev/docs', [
      web(3, 34, 'http://api.example.com.mirror.dev/docs'),
    ]);
  });

  test('a colon after a bare host stays out of the link', () {
    expectLinks('see example.com: x', [web(4, 15, 'http://example.com')]);
  });

  test('a www. host keeps a trailing slash and its path', () {
    expectLinks('see www.example.com/ x', [
      web(4, 20, 'http://www.example.com/'),
    ]);
    expectLinks('example.org:8443/docs?id=7', [
      web(0, 26, 'http://example.org:8443/docs?id=7'),
    ]);
  });

  test(
    'a non-ASCII label of a script NSDataDetector takes links in any host',
    () {
      expectLinks('see пример.рф x', [web(4, 13, 'http://пример.рф')]);
      expectLinks('see example.bücher.com x', [
        web(4, 22, 'http://example.bücher.com'),
      ]);
      expectLinks('see 한국.kr x', [web(4, 9, 'http://한국.kr')]);
    },
  );

  test("a Hebrew, Arabic, Han, kana or Thai label links where the host's first label is www", () {
    expectLinks('see www.例子.com x', [web(4, 14, 'http://www.例子.com')]);
    expectLinks('see WWW.例子.com x', [web(4, 14, 'http://WWW.例子.com')]);
    expectLinks('see www.example.例子.com x', [
      web(4, 22, 'http://www.example.例子.com'),
    ]);
    expectLinks('see www.例子.example.com x', [
      web(4, 22, 'http://www.例子.example.com'),
    ]);
    expectLinks('see www.example.דוגמה.com x', [
      web(4, 25, 'http://www.example.דוגמה.com'),
    ]);
    expectLinks('see example.www.例子.com x', const []);
  });

  test(
    "a Lao label does not link, even where the host's first label is www",
    () {
      expectLinks('see www.example.ລາວ.com x', const []);
    },
  );

  test('a host whose first label is www links on any listed ASCII TLD', () {
    expectLinks('see www.bücher.app x', [web(4, 18, 'http://www.bücher.app')]);
    expectLinks('see www.例子.app x', [web(4, 14, 'http://www.例子.app')]);
    expectLinks('see www.example.рф x', [web(4, 18, 'http://www.example.рф')]);
    expectLinks('see www.bücher.zzz x', const []);
  });

  test("an IDN TLD among NSDataDetector's twelve links after a label of another script", () {
    expectLinks('see bücher.ไทย x', [web(4, 14, 'http://bücher.ไทย')]);
    expectLinks('see bücher.مصر x', [web(4, 14, 'http://bücher.مصر')]);
  });

  test(
    'an unspaced-script first label links only where the first label is www',
    () {
      expectLinks('see 例子.com x', const []);
      expectLinks('see ไทย.com x', const []);
      expectLinks('see example.例子.com x', const []);
      expectLinks('访问 例子.中国 吧', const []);
    },
  );

  test('a first label outside ASCII and the unspaced scripts links its host whole on an IANA TLD', () {
    expectLinks('éwww.banlu.app/x', [
      web(0, 16, 'http://éwww.banlu.app/x'),
    ], apple: const []);
    expectLinks('see דוגמה.com x', [
      web(4, 13, 'http://דוגמה.com'),
    ], apple: const []);
    expectLinks('see bücher.app x', [
      web(4, 14, 'http://bücher.app'),
    ], apple: const []);
  });

  test(
    'an ASCII label under an unspaced-script TLD makes the host no link',
    () {
      expectLinks(
        'see example.ไทย now',
        const [],
        apple: [web(4, 15, 'http://example.ไทย')],
      );
      expectLinks(
        'see example.한국 now',
        const [],
        apple: [web(4, 14, 'http://example.한국')],
      );
      expectLinks(
        'see é.example.ไทย x',
        const [],
        apple: [web(4, 17, 'http://é.example.ไทย')],
      );
    },
  );

  test('a non-ASCII label under an unspaced-script TLD links', () {
    expectLinks('see 한국.한국 x', [web(4, 9, 'http://한국.한국')]);
    expectLinks('see éa.ไทย x', [web(4, 10, 'http://éa.ไทย')]);
  });

  test('the IANA list decides the TLD of a host with a non-ASCII label', () {
    expectLinks('see example.bücher.app x', [
      web(4, 22, 'http://example.bücher.app'),
    ], apple: const []);
    expectLinks('see 한국.app x', [web(4, 10, 'http://한국.app')], apple: const []);
    expectLinks('see example.ελ x', [
      web(4, 14, 'http://example.ελ'),
    ], apple: const []);
    expectLinks('see example.דוגמה.com x', [
      web(4, 21, 'http://example.דוגמה.com'),
    ], apple: const []);
    expectLinks('see www.example.ελ x', [
      web(4, 18, 'http://www.example.ελ'),
    ], apple: const []);
    expectLinks('see www.例子.中国 x', [
      web(4, 13, 'http://www.例子.中国'),
    ], apple: const []);
    expectLinks('see www.example.বাংলা.com x', [
      web(4, 25, 'http://www.example.বাংলা.com'),
    ], apple: const []);
  });

  test("a host's label that NSDataDetector cuts at a '-' and a letter or digit gives no link", () {
    expectLinks(
      'www.my-site.example.orgé',
      const [],
      apple: [web(0, 6, 'http://www.my')],
    );
    expectLinks('see www.example.com-x y', [
      web(4, 19, 'http://www.example.com'),
    ]);
  });

  test('a TLD a letter or digit follows directly gives no link', () {
    expectLinks('한국어x.ai1', const [], apple: [web(3, 7, 'http://x.ai')]);
    expectLinks('x.ai1', const []);
    expectLinks('한국어x.ai-1', [web(3, 7, 'http://x.ai')]);
  });

  test("a bare host right before '://' is that scheme's text", () {
    expectLinks(
      '1.tg://a.io/a x',
      [web(2, 13, 'tg://a.io/a')],
      apple: [web(0, 4, 'http://1.tg')],
    );
    expectLinks('see example.com://x y', [web(4, 19, 'example.com://x')]);
  });
}
