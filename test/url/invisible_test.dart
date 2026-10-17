@Skip('the Dart detector does not read invisible characters yet')
library;

import 'package:flutter_test/flutter_test.dart';

import 'links.dart';

void main() {
  test("an invisible character inside a scheme link's host stays in its text and leaves its URL", () {
    expectLinks('see https://exam\u200Bple.com x', [
      web(4, 24, 'https://example.com'),
    ]);
  });

  test("an invisible character inside a link's path stays in its text and leaves its URL", () {
    expectLinks('see example.com/a\u200Bb x', [
      web(4, 19, 'http://example.com/ab'),
    ]);
    expectLinks('see https://example.com/a\u2060b x', [
      web(4, 27, 'https://example.com/ab'),
    ]);
    expectLinks('see https://example.com/a\uFEFFb x', [
      web(4, 27, 'https://example.com/ab'),
    ]);
    expectLinks('see https://example.com/a\u206Ab x', [
      web(4, 27, 'https://example.com/ab'),
    ]);
  });

  test(
    "a link's span covers a trailing invisible character its URL leaves out",
    () {
      expectLinks('_ftp://a.io/a#\u200B x', [web(1, 15, 'ftp://a.io/a#')]);
      expectLinks('see example.com/a#\u200B x', [
        web(4, 19, 'http://example.com/a#'),
      ]);
    },
  );

  test("a soft hyphen stays in a link's URL", () {
    expectLinks('see https://example.com/a\u00ADb x', [
      web(4, 27, 'https://example.com/a\u00ADb'),
    ]);
  });

  test('a no-break space, a line separator, an ideographic space or a next line ends a link', () {
    expectLinks('see https://example.com/a\u00A0b x', [
      web(4, 25, 'https://example.com/a'),
    ]);
    expectLinks('see https://example.com/a\u2028b x', [
      web(4, 25, 'https://example.com/a'),
    ]);
    expectLinks('see https://example.com/a\u3000b x', [
      web(4, 25, 'https://example.com/a'),
    ]);
    expectLinks('see https://example.com/a\u0085b x', [
      web(4, 25, 'https://example.com/a'),
    ]);
  });

  test('the any-scheme pass ends a link before a zero-width no-break space, ogham space or medium mathematical space', () {
    expectLinks('"http://example.com/a?b=1?\uFEFF. Then', [
      web(1, 27, 'http://example.com/a?b=1?'),
    ]);
    expectLinks('"http://example.com/a?b=1?\u1680. Then', [
      web(1, 26, 'http://example.com/a?b=1?'),
    ]);
    expectLinks('"http://example.com/a?b=1?\u205F. Then', [
      web(1, 26, 'http://example.com/a?b=1?'),
    ]);
  });

  test('a format character before a bare host stays outside it', () {
    expectLinks('see \u200Dexample.com', [web(5, 16, 'http://example.com')]);
    expectLinks('see \u00ADexample.com x', [web(5, 16, 'http://example.com')]);
  });

  test('a format character inside a bare host makes it no link', () {
    expectLinks('see exam\u200Dple.com x', const []);
    expectLinks('see example\u200B.com x', const []);
  });

  test(
    'no word boundary falls before a zero-width joiner after a bare host',
    () {
      expectLinks('see 10.0.0.1\u200D x', const []);
      expectLinks('see example.com\u200D x', const []);
    },
  );

  test('a variation selector in a path ends a bare domain link', () {
    expectLinks('see example.com/a\u{E0100}b x', [
      web(4, 17, 'http://example.com/a'),
    ]);
    expectLinks('see example.com/a\u{E0100}b y.com/z x', [
      web(4, 17, 'http://example.com/a'),
      web(21, 28, 'http://y.com/z'),
    ]);
  });

  test('a combining mark stays in a path', () {
    expectLinks('see example.com/a\u0301b x', [
      web(4, 19, 'http://example.com/a\u0301b'),
    ]);
  });
}
