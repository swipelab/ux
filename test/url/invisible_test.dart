@Skip('the Dart detector does not read invisible characters yet')
library;

import 'package:flutter_test/flutter_test.dart';

import 'links.dart';

void main() {
  test("a link ends before an invisible space inside a scheme link's host, and the rest of the host starts no link", () {
    expectLinks(
      'see https://exam\u200Bple.com x',
      [web(4, 16, 'https://exam')],
      apple: [web(4, 24, 'https://example.com')],
    );
  });

  test('a link ends before an invisible space inside its path', () {
    expectLinks(
      'see example.com/a\u200Bb x',
      [web(4, 17, 'http://example.com/a')],
      apple: [web(4, 19, 'http://example.com/ab')],
    );
    expectLinks(
      'see https://example.com/a\u2060b x',
      [web(4, 25, 'https://example.com/a')],
      apple: [web(4, 27, 'https://example.com/ab')],
    );
    expectLinks(
      'see https://example.com/a\uFEFFb x',
      [web(4, 25, 'https://example.com/a')],
      apple: [web(4, 27, 'https://example.com/ab')],
    );
    expectLinks(
      'see https://example.com/a\u206Ab x',
      [web(4, 25, 'https://example.com/a')],
      apple: [web(4, 27, 'https://example.com/ab')],
    );
  });

  test('a link ends before a trailing invisible space', () {
    expectLinks(
      'see https://example.com\u200B x',
      [web(4, 23, 'https://example.com')],
      apple: [web(4, 24, 'https://example.com')],
    );
    expectLinks(
      '_ftp://a.io/a#\u200B x',
      [web(1, 14, 'ftp://a.io/a#')],
      apple: [web(1, 15, 'ftp://a.io/a#')],
    );
    expectLinks(
      'see example.com/a#\u200B x',
      [web(4, 18, 'http://example.com/a#')],
      apple: [web(4, 19, 'http://example.com/a#')],
    );
  });

  test("an invisible space right after a scheme's '://' leaves no link", () {
    expectLinks(
      'https://\u1680docs.flutter.dev',
      const [],
      apple: [web(0, 25, 'https://\u1680docs.flutter.dev')],
    );
  });

  test('a scheme and its slashes alone that an invisible space ends are no link, and a host after an invisible space no link holds still links', () {
    expectLinks(
      'see tel://\u200B+15551234567 x',
      const [],
      apple: [web(4, 23, 'tel://+15551234567')],
    );
    expectLinks(
      'webcal:/\u200C/example.com',
      const [],
      apple: [web(0, 21, 'webcal://example.com')],
    );
    expectLinks(
      'see webcal://\u1680example.com/cal.ics x',
      [web(14, 33, 'http://example.com/cal.ics')],
      apple: [
        web(4, 13, 'webcal://'),
        web(14, 33, 'http://example.com/cal.ics'),
      ],
    );
  });

  test(
    'an invisible space in a link that another link hides cuts off no text',
    () {
      expectLinks('see b\u00FCcher.de/xhttps://a\u200B.flutter.dev/setup x', [
        web(4, 24, 'http://b\u00FCcher.de/xhttps://a'),
        web(26, 43, 'http://flutter.dev/setup'),
      ]);
    },
  );

  test("a zero-width joiner inside a word stays in a link's text and leaves its URL", () {
    expectLinks('see https://\u0915\u094D\u200D\u0937.com x', [
      web(4, 20, 'https://\u0915\u094D\u0937.com'),
    ]);
  });

  test("an address ends before a Hangul filler in its domain, and the rest of the domain starts no link", () {
    expectLinks(
      'mail ops@exam\u3164ple.com now',
      const [],
      apple: [email(5, 21, 'mailto:ops@example.com')],
    );
  });

  test("a Hangul filler in an address's local part stays in the address and its URL", () {
    expectLinks('mail o\u3164ps@example.com now', [
      email(5, 21, 'mailto:o%E3%85%A4ps@example.com'),
    ]);
  });

  test("a Hangul filler in the domain of an address that mailto: without '//' starts stays in the address and its URL", () {
    expectLinks('see mailto:ops@exam\u3164ple.com x', [
      email(4, 27, 'mailto:ops@exam%E3%85%A4ple.com'),
    ]);
  });

  test('a phone ends before an ogham space mark, and no phone links where too few digits precede it', () {
    expectLinks(
      'call +1 555\u1680123 4567 now',
      const [],
      apple: [phone(5, 20, 'tel:+15551234567')],
    );
  });

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

  test("a link ends before a zero-width no-break space, an ogham space mark or a medium mathematical space after its '?'", () {
    expectLinks(
      '"http://example.com/a?b=1?\uFEFF. Then',
      [web(1, 26, 'http://example.com/a?b=1?')],
      apple: [web(1, 27, 'http://example.com/a?b=1?')],
    );
    expectLinks('"http://example.com/a?b=1?\u1680. Then', [
      web(1, 26, 'http://example.com/a?b=1?'),
    ]);
    expectLinks('"http://example.com/a?b=1?\u205F. Then', [
      web(1, 26, 'http://example.com/a?b=1?'),
    ]);
  });

  test('a format character before a bare host stays outside it', () {
    expectLinks('see \u200Dexample.com', [web(5, 16, 'http://example.com')]);
  });

  test('a bare host ends before a zero-width space where what precedes it ends in a listed TLD', () {
    expectLinks('see example.co\u200Bm x', [web(4, 14, 'http://example.co')]);
  });

  test('a format character inside a bare host makes it no link', () {
    expectLinks('see exam\u200Dple.com x', const []);
  });

  test(
    'no word boundary falls before a zero-width joiner after a bare host',
    () {
      expectLinks('see 10.0.0.1\u200D x', const []);
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
