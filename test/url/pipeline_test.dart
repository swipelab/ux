@Skip('the Dart detector does not read the pipeline yet')
library;

import 'package:flutter_test/flutter_test.dart';

import 'links.dart';

void main() {
  test('a web link, an email and a phone in one text', () {
    expectLinks(
      'see https://example.com/a?b=1, mail ops@example.com or call +40 712 345 678',
      [
        web(4, 29, 'https://example.com/a?b=1'),
        email(36, 51, 'mailto:ops@example.com'),
        phone(60, 75, 'tel:+40712345678'),
      ],
    );
  });

  test('a text with nothing to link has no links', () {
    expectLinks('nothing to see here', const []);
  });

  test('an email wins over the web link of its domain at the same start', () {
    expectLinks('write to first.last+tag@sub.example.co.uk today', [
      email(9, 41, 'mailto:first.last+tag@sub.example.co.uk'),
    ]);
  });

  test('a phone wins over a web link of the same span', () {
    expectLinks('ip 010.000.000.001 x', [phone(3, 18, 'tel:010000000001')]);
  });

  test('a web link that starts first hides the phone inside it', () {
    expectLinks('ip 123.45.67.89/x', [web(3, 17, 'http://123.45.67.89/x')]);
  });

  test('a phone the phone filter drops still hides the link it overlaps', () {
    expectLinks('x 555 123 45.67.89.10 y', const []);
  });

  test('the any-scheme pass adds the links past the cap of 64', () {
    expectLinks(List.filled(70, 'https://a.com').join(' '), [
      for (var i = 0; i < 70; i++) web(i * 14, i * 14 + 13, 'https://a.com'),
    ]);
  });

  test('the cap of 64 drops a native link past it', () {
    expectLinks('${List.filled(66, 'https://a.com').join(' ')} b.com', [
      for (var i = 0; i < 66; i++) web(i * 14, i * 14 + 13, 'https://a.com'),
    ]);
  });

  test(
    'the any-scheme link that starts first wins over the native link inside it',
    () {
      expectLinks('1https://a.com x', [web(1, 14, 'https://a.com')]);
    },
  );

  test(
    'the any-scheme link that runs past the native link from its start wins',
    () {
      expectLinks('see http://example.com/a\uE000b x', [
        web(4, 26, 'http://example.com/a\uE000b'),
      ]);
    },
  );

  test('a native link that ties the any-scheme link keeps its span and the URL leaves out a zero-width space', () {
    expectLinks('"ftp://a.io/a#\u200B +15551234567', [
      web(1, 15, 'ftp://a.io/a#'),
      phone(16, 28, 'tel:+15551234567'),
    ]);
  });

  test(
    "no email or phone past a fullwidth parenthesis continues a link's path",
    () {
      expectLinks(
        'https://example.com/a（1）/x?m=a@b.com',
        [web(0, 21, 'https://example.com/a')],
        apple: [
          web(0, 21, 'https://example.com/a'),
          email(25, 36, 'mailto:x?m=a@b.com'),
        ],
      );
      expectLinks('https://example.com/a（1）/+1-555-123-4567', [
        web(0, 21, 'https://example.com/a'),
      ]);
    },
  );

  test(
    "no any-scheme link past a fullwidth parenthesis continues a link's path",
    () {
      expectLinks(
        'https://example.com/a（1）/x/tg://a.io',
        [web(0, 21, 'https://example.com/a')],
        apple: [web(0, 21, 'https://example.com/a'), web(27, 36, 'tg://a.io')],
      );
      expectLinks(
        'https://example.com/a（1）/x/http://evil.com',
        [web(0, 21, 'https://example.com/a')],
        apple: [
          web(0, 21, 'https://example.com/a'),
          web(27, 42, 'http://evil.com'),
        ],
      );
      expectLinks(
        'https://example.com/a（1）/x?u=bl://chat/1',
        [web(0, 21, 'https://example.com/a')],
        apple: [
          web(0, 21, 'https://example.com/a'),
          web(29, 40, 'bl://chat/1'),
        ],
      );
    },
  );
}
