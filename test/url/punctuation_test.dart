import 'package:flutter_test/flutter_test.dart';

import 'links.dart';

void main() {
  test("a link ends before a trailing '.', ',', ';' or '!'", () {
    expectLinks('see https://example.com/a?b=1,', [
      web(4, 29, 'https://example.com/a?b=1'),
    ]);
    expectLinks('see https://example.com/a,b,c,', [
      web(4, 29, 'https://example.com/a,b,c'),
    ]);
    expectLinks('Open banlu.app/t/8821, then reply', [
      web(5, 21, 'http://banlu.app/t/8821'),
    ]);
    expectLinks('http://banlu.app/a.', [web(0, 18, 'http://banlu.app/a')]);
  });

  test("a link ends before a trailing '('", () {
    expectLinks('see https://example.com/a(', [
      web(4, 25, 'https://example.com/a'),
    ]);
  });

  test("a trailing '?' stays in a link", () {
    expectLinks('tg://resolve?domain=abc?', [
      web(0, 24, 'tg://resolve?domain=abc?'),
    ]);
    expectLinks('see https://example.com? x', [
      web(4, 24, 'https://example.com?'),
    ]);
    expectLinks('see example.com? x', [web(4, 16, 'http://example.com?')]);
  });

  test("a trailing ':' after a path, query or fragment stays in a link", () {
    expectLinks('see banlu://chat/42: y', [web(4, 20, 'banlu://chat/42:')]);
    expectLinks('Server https://example.com#status: down', [
      web(7, 34, 'https://example.com#status:'),
    ]);
    expectLinks('see http://[::1]:80/: up', [web(4, 21, 'http://[::1]:80/:')]);
  });

  test("a trim mark before a kept '?' stays", () {
    expectLinks('see https://example.com#a.? y', [
      web(4, 27, 'https://example.com#a.?'),
    ]);
  });

  test("a trim mark after a trailing '?' or ':' goes", () {
    expectLinks('see https://example.com/a?. x', [
      web(4, 26, 'https://example.com/a?'),
    ]);
    expectLinks('see https://example.com/a:. x', [
      web(4, 26, 'https://example.com/a:'),
    ]);
  });

  test("ASCII path marks other than the trim marks stay at a link's end", () {
    expectLinks('see https://example.com/a* x', [
      web(4, 26, 'https://example.com/a*'),
    ]);
    expectLinks('see https://example.com/a~ x', [
      web(4, 26, 'https://example.com/a~'),
    ]);
    expectLinks('see https://example.com/a# x', [
      web(4, 26, 'https://example.com/a#'),
    ]);
    expectLinks('see example.com/a- x', [web(4, 18, 'http://example.com/a-')]);
    expectLinks('see https://example.com/ x', [
      web(4, 24, 'https://example.com/'),
    ]);
  });

  test("a ')' a link opens stays in it", () {
    expectLinks('(see https://example.com/a_(b)).', [
      web(5, 30, 'https://example.com/a_(b)'),
    ]);
    expectLinks('see bl://chat/a_(b) x', [web(4, 19, 'bl://chat/a_(b)')]);
  });

  test("an unopened ')' after a host ends the link with what follows it", () {
    expectLinks('Have you read the docs (https://docs.flutter.dev)?', [
      web(24, 48, 'https://docs.flutter.dev'),
    ]);
    expectLinks(
      'see (example.com/a)? x',
      [web(5, 18, 'http://example.com/a')],
      apple: [web(5, 20, 'http://example.com/a)?')],
    );
  });

  test(
    "an unopened ')' that only trailing punctuation follows ends the link",
    () {
      expectLinks('(https://docs.flutter.dev#setup)?', [
        web(1, 31, 'https://docs.flutter.dev#setup'),
      ]);
      expectLinks('Have you read the guide (https://docs.flutter.dev#setup)?', [
        web(25, 55, 'https://docs.flutter.dev#setup'),
      ]);
      expectLinks(
        '(https://docs.flutter.dev/setup)?',
        [web(1, 31, 'https://docs.flutter.dev/setup')],
        apple: [web(1, 33, 'https://docs.flutter.dev/setup)?')],
      );
      expectLinks(
        '(https://docs.flutter.dev/setup): x',
        [web(1, 31, 'https://docs.flutter.dev/setup')],
        apple: [web(1, 33, 'https://docs.flutter.dev/setup):')],
      );
      expectLinks(
        'Have you read the guide (https://docs.flutter.dev/setup)? yes',
        [web(25, 55, 'https://docs.flutter.dev/setup')],
        apple: [web(25, 57, 'https://docs.flutter.dev/setup)?')],
      );
      expectLinks(
        '(https://docs.flutter.dev?q=1)?',
        [web(1, 29, 'https://docs.flutter.dev?q=1')],
        apple: [web(1, 31, 'https://docs.flutter.dev?q=1)?')],
      );
    },
  );

  test(
    "an unopened ')' that a mark other than trailing punctuation follows stays",
    () {
      expectLinks('(https://a.com#frag)-', [
        web(1, 21, 'https://a.com#frag)-'),
      ]);
      expectLinks('(https://a.com#frag)»', [
        web(1, 21, 'https://a.com#frag)»'),
      ]);
    },
  );

  test("an unopened ')' counts the parentheses before it", () {
    expectLinks('see bl://x/a)b(c)? y', [web(4, 16, 'bl://x/a)b(c')]);
    expectLinks('bl://a/x?)?', [web(0, 9, 'bl://a/x?')]);
  });

  test('a parenthesis inside a path stays', () {
    expectLinks('see https://example.com/(a) x', [
      web(4, 27, 'https://example.com/(a)'),
    ]);
    expectLinks('see https://example.com/a(b x', [
      web(4, 27, 'https://example.com/a(b'),
    ]);
    expectLinks('see https://example.com/a)b x', [
      web(4, 27, 'https://example.com/a)b'),
    ]);
  });

  test('a link ends before an ASCII bracket or quote around it', () {
    expectLinks("He said 'https://example.com/a'.", [
      web(9, 30, 'https://example.com/a'),
    ]);
    expectLinks('see "example.com/a" x', [web(5, 18, 'http://example.com/a')]);
    expectLinks('see <https://example.com/a> x', [
      web(5, 26, 'https://example.com/a'),
    ]);
    expectLinks('see `https://example.com/a`', [
      web(5, 26, 'https://example.com/a'),
    ]);
  });

  test('a link ends before a trailing closing curly quote or ellipsis', () {
    expectLinks(
      'see “https://example.com/a” x',
      [web(5, 26, 'https://example.com/a')],
      apple: [web(5, 27, 'https://example.com/a”')],
    );
    expectLinks(
      'see https://example.com/a… x',
      [web(4, 25, 'https://example.com/a')],
      apple: [web(4, 26, 'https://example.com/a…')],
    );
    expectLinks(
      'see https://example.com/a’ x',
      [web(4, 25, 'https://example.com/a')],
      apple: [web(4, 26, 'https://example.com/a’')],
    );
  });

  test('an opening curly quote is no part of a bare host', () {
    expectLinks(
      'see “example.com/a” x',
      [web(5, 18, 'http://example.com/a')],
      apple: [web(5, 19, 'http://example.com/a”')],
    );
  });

  test('a link ends before its trailing non-ASCII symbols where a non-word character follows', () {
    expectLinks(
      '_http://example.com/a😀 x',
      [web(1, 21, 'http://example.com/a')],
      apple: [web(1, 23, 'http://example.com/a😀')],
    );
    expectLinks(
      '_http://example.com:8080@例子.com/😀 y',
      [web(1, 32, 'http://example.com:8080@例子.com/')],
      apple: [web(1, 34, 'http://example.com:8080@例子.com/😀')],
    );
    expectLinks(
      'see example.com/a😀- x',
      [web(4, 17, 'http://example.com/a')],
      apple: [web(4, 20, 'http://example.com/a😀-')],
    );
    expectLinks(
      'see example.com/a-😀 x',
      [web(4, 18, 'http://example.com/a-')],
      apple: [web(4, 20, 'http://example.com/a-😀')],
    );
  });

  test(
    "a link keeps a non-ASCII symbol at the text's end or inside its path",
    () {
      expectLinks('see https://example.com/a😀', [
        web(4, 27, 'https://example.com/a😀'),
      ]);
      expectLinks('see https://example.com/a€b x', [
        web(4, 27, 'https://example.com/a€b'),
      ]);
    },
  );

  test("the text a cut removes from a link reads as a text of its own, up to the link's old end", () {
    expectLinks(
      'https://a.com(x)/http://[::1]:80/a\uFF1A!. ',
      [web(0, 13, 'https://a.com')],
      apple: [web(0, 24, 'https://a.com(x)/http://')],
    );
  });
}
