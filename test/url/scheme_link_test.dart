@Skip('the Dart detector does not read links with a scheme yet')
library;

import 'package:flutter_test/flutter_test.dart';

import 'links.dart';

void main() {
  test("a scheme link starts at the first letter of the scheme characters before its '://'", () {
    expectLinks('_banlu://chat/42 x', [web(1, 16, 'banlu://chat/42')]);
    expectLinks('see 1a://x', [web(5, 10, 'a://x')]);
    expectLinks('foo _bl://x?code=1)', [web(5, 18, 'bl://x?code=1')]);
  });

  test(
    'a scheme link that a digit glues to wins over the native link inside it',
    () {
      expectLinks('1ftp://a.com/x y', [web(1, 14, 'ftp://a.com/x')]);
    },
  );

  test("a scheme link glued after a letter or '_' takes its userinfo with its host", () {
    expectLinks('x_http://example.com:8080@evil.com/x_', [
      web(2, 37, 'http://example.com:8080@evil.com/x_'),
    ]);
    expectLinks('_http://example.com:8080@evil.com/x_', [
      web(1, 36, 'http://example.com:8080@evil.com/x_'),
    ]);
    expectLinks('_http://example.com:8080@例子.com/x y', [
      web(1, 33, 'http://example.com:8080@例子.com/x'),
    ]);
  });

  test("a link with any scheme before '://' links", () {
    expectLinks('see h://x now', [web(4, 9, 'h://x')]);
    expectLinks('see a1+b.c-d://x/y now', [web(4, 18, 'a1+b.c-d://x/y')]);
    expectLinks('see intent://scan/#Intent;end now', [
      web(4, 29, 'intent://scan/#Intent;end'),
    ]);
    expectLinks('see file:///etc/passwd now', [
      web(4, 22, 'file:///etc/passwd'),
    ]);
  });

  test('a scheme link in capitals links as written', () {
    expectLinks('see HTTPS://EXAMPLE.COM/A now', [
      web(4, 25, 'HTTPS://EXAMPLE.COM/A'),
    ]);
  });

  test("a scheme and its '://' alone are no link", () {
    expectLinks('see https:// y', const []);
    expectLinks('HTTPS://:A.COM', [web(9, 14, 'http://A.COM')]);
  });

  test("a userinfo runs through the last '@' before the path", () {
    expectLinks('see https://a@b@c.com/x y', [
      web(4, 23, 'https://a@b@c.com/x'),
    ]);
    expectLinks('see http://user:pass@example.com/x x', [
      web(4, 34, 'http://user:pass@example.com/x'),
    ]);
  });

  test("a link's path ends before a mark its URL cannot hold", () {
    expectLinks('see https://www.google.com/search?q=(cats|dogs) x', [
      web(4, 41, 'https://www.google.com/search?q=(cats'),
    ]);
    expectLinks('see https://example.com/a^b x', [
      web(4, 25, 'https://example.com/a'),
    ]);
    expectLinks('see https://example.com/a"b x', [
      web(4, 25, 'https://example.com/a'),
    ]);
  });

  test("a '%' that two hex digits don't follow ends a link's path", () {
    expectLinks('see https://example.com/a%2 x', [
      web(4, 25, 'https://example.com/a'),
    ]);
    expectLinks('see https://example.com/a%zz x', [
      web(4, 25, 'https://example.com/a'),
    ]);
  });

  test(
    "a link's URL keeps the escapes and the non-ASCII characters of its text",
    () {
      expectLinks('see https://example.com/路径%20x y', [
        web(4, 30, 'https://example.com/路径%20x'),
      ]);
      expectLinks('see https://WWW.例子.com/路径%20x y', [
        web(4, 29, 'https://WWW.例子.com/路径%20x'),
      ]);
      expectLinks('see https://example.com/a%20b] x', [
        web(4, 29, 'https://example.com/a%20b'),
      ]);
      expectLinks('visit https://bücher.example/straße today', [
        web(6, 35, 'https://bücher.example/straße'),
      ]);
    },
  );

  test('a single-label host links after a scheme', () {
    expectLinks('see http://intranet/x x', [web(4, 21, 'http://intranet/x')]);
    expectLinks('see http://localhost:3000/x x', [
      web(4, 27, 'http://localhost:3000/x'),
    ]);
  });

  test("a scheme link's host ends before a sub-delimiter or '~'", () {
    expectLinks(
      'see https://a.com!b x',
      [web(4, 17, 'https://a.com')],
      apple: [web(4, 19, 'https://a.com!b')],
    );
    expectLinks(
      'see https://a.com,b.com x',
      [web(4, 17, 'https://a.com')],
      apple: [web(4, 23, 'https://a.com,b.com')],
    );
    expectLinks(
      'see https://a.com~b x',
      [web(4, 17, 'https://a.com')],
      apple: [web(4, 19, 'https://a.com~b')],
    );
  });

  test("a scheme link's host ends before a parenthesis", () {
    expectLinks(
      'see https://a.com(a(b)c) y',
      [web(4, 17, 'https://a.com')],
      apple: [web(4, 24, 'https://a.com(a(b)c)')],
    );
    expectLinks(
      'https://a.com(x))?x',
      [web(0, 13, 'https://a.com')],
      apple: [web(0, 19, 'https://a.com(x))?x')],
    );
    expectLinks(
      'see https://a.com(x) y',
      [web(4, 17, 'https://a.com')],
      apple: [web(4, 20, 'https://a.com(x)')],
    );
    expectLinks(
      'see https://a.com(a(b(c)d)e) y',
      [web(4, 17, 'https://a.com')],
      apple: [web(4, 28, 'https://a.com(a(b(c)d)e)')],
    );
    expectLinks(
      'see https://a.com(a(b) y',
      [web(4, 17, 'https://a.com')],
      apple: [web(4, 22, 'https://a.com(a(b)')],
    );
  });

  test("a CJK full stop ends a scheme link's host", () {
    expectLinks('_http://例子。com x', [web(1, 10, 'http://例子')]);
  });

  test("a scheme link's host takes a percent escape", () {
    expectLinks('see https://a.com%20b x', [web(4, 21, 'https://a.com%20b')]);
  });
}
