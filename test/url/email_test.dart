@Skip('the Dart detector does not read emails yet')
library;

import 'package:flutter_test/flutter_test.dart';

import 'links.dart';

void main() {
  test("an address's local part takes ASCII atext and dots", () {
    expectLinks('mail ops@example.com now', [
      email(5, 20, 'mailto:ops@example.com'),
    ]);
    expectLinks("mail a!b#c\$d%e&f'g*h+i/j=k?l^m_n`o{p|q}r~s@example.com now", [
      email(
        5,
        54,
        "mailto:a!b%23c\$d%25e&f'g*h+i/j=k?l%5Em_n%60o%7Bp%7Cq%7Dr~s@example.com",
      ),
    ]);
    expectLinks('mail a..b@example.com now', [
      email(5, 21, 'mailto:a..b@example.com'),
    ]);
  });

  test("a '.' that starts a local part is left out of the address", () {
    expectLinks('.josé@example.com', [
      email(1, 17, 'mailto:jos%C3%A9@example.com'),
    ]);
  });

  test('a local part takes some non-ASCII letters, which its URL escapes', () {
    expectLinks('mail josé@example.com now', [
      email(5, 21, 'mailto:jos%C3%A9@example.com'),
    ]);
    expectLinks('see ٣한국b@x.com', [
      email(4, 14, 'mailto:%D9%A3%ED%95%9C%EA%B5%ADb@x.com'),
    ]);
  });

  test('a Han local part makes no address outside the Han-TLD shape', () {
    expectLinks('mail 用户@example.com now', [web(8, 19, 'http://example.com')]);
  });

  test("an address's URL escapes '#', '%', '^', '`', '{', '|' and '}' of its local part", () {
    expectLinks('see a|b@x.com', [email(4, 13, 'mailto:a%7Cb@x.com')]);
  });

  test("an address's domain takes IDN labels and an IPv4 address", () {
    expectLinks('mail ops@例子.com now', [
      email(5, 15, 'mailto:ops@xn--fsqu00a.com'),
    ]);
    expectLinks('ops@10.0.0.1', [email(0, 12, 'mailto:ops@10.0.0.1')]);
  });

  test("an address's domain label takes '_'", () {
    expectLinks('mail ops@exa_mple.com now', [
      email(5, 21, 'mailto:ops@exa_mple.com'),
    ]);
  });

  test("a combining mark in an address's domain makes no address", () {
    expectLinks('mail ops@Bu\u0308cher.de now', const []);
  });

  test("an ASCII domain stays as written in the address's URL", () {
    expectLinks('mail ops@EXAMPLE.COM now', [
      email(5, 20, 'mailto:ops@EXAMPLE.COM'),
    ]);
    expectLinks('ops@Example.APP', [email(0, 15, 'mailto:ops@Example.APP')]);
  });

  test(
    "a non-ASCII domain becomes its UTS-46 ToASCII in the address's URL",
    () {
      expectLinks('mail ops@Bücher.de now', [
        email(5, 18, 'mailto:ops@xn--bcher-kva.de'),
      ]);
      expectLinks('mail ops@ﬁx.com now', [email(5, 15, 'mailto:ops@fix.com')]);
      expectLinks('mail ops@straße.de now', [
        email(5, 18, 'mailto:ops@xn--strae-oqa.de'),
      ]);
      expectLinks('mail ops@例子.COM now', [
        email(5, 15, 'mailto:ops@xn--fsqu00a.com'),
      ]);
    },
  );

  test("a domain with no TLD, an empty label, a bracketed literal or a misplaced '-' or '@' makes no address", () {
    expectLinks('mail ops@localhost now', const []);
    expectLinks('mail ops@example..com now', const []);
    expectLinks('mail ops@[10.0.0.1] now', [web(10, 18, 'http://10.0.0.1')]);
    expectLinks('mail ops@-example.com now', [
      web(10, 21, 'http://example.com'),
    ]);
    expectLinks('mail ops@@example.com now', [
      web(10, 21, 'http://example.com'),
    ]);
  });

  test("an address's domain ends in an IANA TLD", () {
    expectLinks(
      'mail ops@example.zzz now',
      const [],
      apple: [email(5, 20, 'mailto:ops@example.zzz')],
    );
    expectLinks(
      'mail a@b.c now',
      const [],
      apple: [email(5, 10, 'mailto:a@b.c')],
    );
    expectLinks(
      'mail ops@example.com.Then you',
      const [],
      apple: [email(5, 25, 'mailto:ops@example.com.Then')],
    );
    expectLinks('ops@example.한국', [
      email(0, 14, 'mailto:ops@example.xn--3e0b707e'),
    ]);
  });

  test('an address on one of the twelve IDN TLDs links anywhere', () {
    expectLinks('mail ops@example.한국 now', [
      email(5, 19, 'mailto:ops@example.xn--3e0b707e'),
    ]);
  });

  test('an address on a Han TLD links where its local part starts a line', () {
    expectLinks('ops@example.中国 now', [
      email(0, 14, 'mailto:ops@example.xn--fiqs8s'),
    ]);
    expectLinks('\u000Aops@example.中国', [
      email(1, 15, 'mailto:ops@example.xn--fiqs8s'),
    ]);
    expectLinks('\u000Dops@example.中国', [
      email(1, 15, 'mailto:ops@example.xn--fiqs8s'),
    ]);
    expectLinks('\u2028ops@example.中国', [
      email(1, 15, 'mailto:ops@example.xn--fiqs8s'),
    ]);
    expectLinks('x\u000Aops@example.中国 now', [
      email(2, 16, 'mailto:ops@example.xn--fiqs8s'),
    ]);
  });

  test('an address on a Han TLD gives none where its local part does not start a line', () {
    expectLinks(' ops@example.中国', const []);
    expectLinks('\u2029ops@example.中国', const []);
    expectLinks('\u000A ops@example.中国', const []);
  });

  test('a line-start local part on a Han TLD starts with a letter or digit and may hold Han', () {
    expectLinks('请联系ops@example.中国', [
      email(0, 17, 'mailto:%E8%AF%B7%E8%81%94%E7%B3%BBops@example.xn--fiqs8s'),
    ]);
    expectLinks('用户@example.中国', [
      email(0, 13, 'mailto:%E7%94%A8%E6%88%B7@example.xn--fiqs8s'),
    ]);
    expectLinks('1ops@example.中国 now', [
      email(0, 15, 'mailto:1ops@example.xn--fiqs8s'),
    ]);
    expectLinks('_ops@example.中国 now', const []);
    expectLinks('联系 ops@example.中国', const []);
    expectLinks('_ops@example.com now', [
      email(0, 16, 'mailto:_ops@example.com'),
    ]);
  });

  test('an address on another non-ASCII TLD gives none', () {
    expectLinks('ops@example.みんな', const []);
    expectLinks('ops@example.公司 now', const []);
    expectLinks('ops@example.例子 now', const []);
    expectLinks('mail ops@example.пример now', const []);
  });

  test('an address keeps a written mailto: and a query', () {
    expectLinks('see mailto:ops@example.com?subject=hi now', [
      email(4, 37, 'mailto:ops@example.com?subject=hi'),
    ]);
  });

  test(
    'an address ends before trailing punctuation and brackets around it',
    () {
      expectLinks('mail ops@example.com, then', [
        email(5, 20, 'mailto:ops@example.com'),
      ]);
      expectLinks('mail (ops@example.com) now', [
        email(6, 21, 'mailto:ops@example.com'),
      ]);
    },
  );

  test('UTF-16 offsets count a supplementary character as two', () {
    expectLinks('😀 ops@example.com or https://example.com/😀', [
      email(3, 18, 'mailto:ops@example.com'),
      web(22, 44, 'https://example.com/😀'),
    ]);
  });

  test("an address EMAIL_ADDRESS reads where Apple's starts later wins over its domain's web link", () {
    expectLinks(
      '@banlu.app@x.com',
      [email(1, 16, 'mailto:banlu.app@x.com')],
      apple: [web(11, 16, 'http://x.com')],
    );
    expectLinks(
      'ຂໍ້ມູນexample.com@x.com',
      [email(6, 23, 'mailto:example.com@x.com')],
      apple: [web(18, 23, 'http://x.com')],
    );
    expectLinks(
      'ip Https://192.168.1.254:8080٣/a|b@x.com',
      [
        web(3, 32, 'Https://192.168.1.254:8080٣/a'),
        email(33, 40, 'mailto:b@x.com'),
      ],
      apple: [
        web(3, 32, 'Https://192.168.1.254:8080٣/a'),
        web(35, 40, 'http://x.com'),
      ],
    );
    expectLinks(
      'mail a.@example.com',
      [email(5, 19, 'mailto:a.@example.com')],
      apple: [web(8, 19, 'http://example.com')],
    );
    expectLinks(
      'mail .a@example.com',
      [email(5, 19, 'mailto:.a@example.com')],
      apple: [email(6, 19, 'mailto:a@example.com')],
    );
    expectLinks(
      'mail ops@xn--fsqu00a.xn--fiqs8s now',
      [email(5, 31, 'mailto:ops@xn--fsqu00a.xn--fiqs8s')],
      apple: [email(5, 23, 'mailto:ops@xn--fsqu00a.xn')],
    );
  });
}
