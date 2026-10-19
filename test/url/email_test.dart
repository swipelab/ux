import 'package:flutter_test/flutter_test.dart';

import 'links.dart';

void main() {
  test("an address's local part is the run of ASCII letters, digits, '.', '_', '%', '+' and '-' before its '@'", () {
    expectLinks('mail ops@example.com now', [
      email(5, 20, 'mailto:ops@example.com'),
    ]);
    expectLinks('mail a..b@example.com now', [
      email(5, 21, 'mailto:a..b@example.com'),
    ]);
    expectLinks('_ops@example.com now', [
      email(0, 16, 'mailto:_ops@example.com'),
    ]);
  });

  test("a character outside the local class ends the local part's run, so the local part starts after it", () {
    expectLinks(
      'see a|b@x.com',
      [email(6, 13, 'mailto:b@x.com')],
      apple: [email(4, 13, 'mailto:a%7Cb@x.com')],
    );
    expectLinks(
      'see ٣한국b@x.com',
      [email(7, 14, 'mailto:b@x.com')],
      apple: [email(4, 14, 'mailto:%D9%A3%ED%95%9C%EA%B5%ADb@x.com')],
    );
  });

  test("a character outside the local class right before the '@' leaves no email, and the text after the '@' reads as any text does", () {
    expectLinks(
      'mail josé@example.com now',
      [web(10, 21, 'http://example.com')],
      apple: [email(5, 21, 'mailto:jos%C3%A9@example.com')],
    );
    expectLinks('mail 用户@example.com now', [web(8, 19, 'http://example.com')]);
  });

  test("an address's URL writes a '%' of its local part as %25", () {
    expectLinks('mail a%b@x.com now', [email(5, 14, 'mailto:a%25b@x.com')]);
  });

  test("a domain with a non-ASCII label or an IPv4 address leaves no email, and the text after the '@' reads as any text does", () {
    expectLinks(
      'mail ops@例子.com now',
      const [],
      apple: [email(5, 15, 'mailto:ops@xn--fsqu00a.com')],
    );
    expectLinks(
      'ops@10.0.0.1',
      [web(4, 12, 'http://10.0.0.1')],
      apple: [email(0, 12, 'mailto:ops@10.0.0.1')],
    );
    expectLinks(
      'mail ops@Bücher.de now',
      [web(9, 18, 'http://Bücher.de')],
      apple: [email(5, 18, 'mailto:ops@xn--bcher-kva.de')],
    );
    expectLinks('mail ops@Bu\u0308cher.de now', [
      web(9, 19, 'http://Bu\u0308cher.de'),
    ], apple: const []);
  });

  test("an address's domain label takes '_'", () {
    expectLinks('mail ops@exa_mple.com now', [
      email(5, 21, 'mailto:ops@exa_mple.com'),
    ]);
  });

  test("an ASCII domain stays as written in the address's URL", () {
    expectLinks('mail ops@EXAMPLE.COM now', [
      email(5, 20, 'mailto:ops@EXAMPLE.COM'),
    ]);
    expectLinks('ops@Example.APP', [email(0, 15, 'mailto:ops@Example.APP')]);
  });

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

  test("an address's domain takes every label its dots join, and its last label is an IANA TLD", () {
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
  });

  test('an address on a non-ASCII TLD gives no email', () {
    expectLinks(
      'mail ops@example.한국 now',
      const [],
      apple: [email(5, 19, 'mailto:ops@example.xn--3e0b707e')],
    );
    expectLinks(
      'ops@example.中国 now',
      const [],
      apple: [email(0, 14, 'mailto:ops@example.xn--fiqs8s')],
    );
  });

  test("a written mailto: keeps a query after the domain, and a '?' that no body character stays after goes", () {
    expectLinks('see mailto:ops@example.com?subject=hi now', [
      email(4, 37, 'mailto:ops@example.com?subject=hi'),
    ]);
    expectLinks('see mailto:ops@example.com?cc=a@b x', [
      email(4, 33, 'mailto:ops@example.com?cc=a@b'),
    ]);
    expectLinks('see mailto:ops@example.com? x', [
      email(4, 26, 'mailto:ops@example.com'),
    ]);
  });

  test("a written mailto: query stays as written in the address's URL", () {
    expectLinks('see mailto:ops@example.com?subject=hi%20there now', [
      email(4, 45, 'mailto:ops@example.com?subject=hi%20there'),
    ]);
  });

  test('an address with no written mailto: takes no query', () {
    expectLinks('see ops@example.com?subject=hi now', [
      email(4, 19, 'mailto:ops@example.com'),
    ]);
  });

  test('a mailto: that no local part follows is text, and an address after it reads as any address does', () {
    expectLinks(
      'see mailto:?to=ops@example.zzz x',
      const [],
      apple: [email(4, 30, 'mailto:?to=ops@example.zzz')],
    );
    expectLinks(
      'see mailto:?to=ops@example.com x',
      [email(15, 30, 'mailto:ops@example.com')],
      apple: [email(4, 30, 'mailto:?to=ops@example.com')],
    );
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
