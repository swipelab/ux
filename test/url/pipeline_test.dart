import 'package:flutter_test/flutter_test.dart';

import 'links.dart';

void main() {
  test('a web link and an email in one text each link', () {
    expectLinks(
      'see https://example.com/a?b=1, mail ops@example.com or call +40 712 345 678',
      [
        web(4, 29, 'https://example.com/a?b=1'),
        email(36, 51, 'mailto:ops@example.com'),
      ],
      apple: [
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

  test('a link ends before a trailing zero-width space', () {
    expectLinks(
      '"ftp://a.io/a#\u200B +15551234567',
      [web(1, 14, 'ftp://a.io/a#')],
      apple: [web(1, 15, 'ftp://a.io/a#'), phone(16, 28, 'tel:+15551234567')],
    );
  });

  test("no email past a fullwidth parenthesis continues a link's path", () {
    expectLinks(
      'https://example.com/a（1）/x?m=a@b.com',
      [web(0, 21, 'https://example.com/a')],
      apple: [
        web(0, 21, 'https://example.com/a'),
        email(25, 36, 'mailto:x?m=a@b.com'),
      ],
    );
  });

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

  test('a text of more than 4,096 units reads up to its last space at or before its 4,096th unit', () {
    expectLinks(
      '${'x ' * 2047}https://example.com',
      const [],
      apple: [web(4094, 4113, 'https://example.com')],
    );
  });

  test('a token links what NSDataDetector reads in its window, from the unit before it to three after it', () {
    expectLinks(
      '\u4E2D\u6587 exa\u034Fmple.co\u2061m x',
      const [],
      apple: [web(7, 14, 'http://mple.co')],
    );
  });
}
