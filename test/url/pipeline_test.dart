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
  }, skip: "step 5 models NSDataDetector's phones");

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
  }, skip: "step 5 models NSDataDetector's phones");

  test('a web link that starts first hides the phone inside it', () {
    expectLinks('ip 123.45.67.89/x', [web(3, 17, 'http://123.45.67.89/x')]);
  });

  test('a phone the phone filter drops still hides the link it overlaps', () {
    expectLinks('x 555 123 45.67.89.10 y', const []);
  }, skip: "step 5 models NSDataDetector's phones");

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

  test('a link ends before a trailing zero-width space and the phone after it links', () {
    expectLinks(
      '"ftp://a.io/a#\u200B +15551234567',
      [web(1, 14, 'ftp://a.io/a#'), phone(16, 28, 'tel:+15551234567')],
      apple: [web(1, 15, 'ftp://a.io/a#'), phone(16, 28, 'tel:+15551234567')],
    );
  }, skip: "step 5 models NSDataDetector's phones");

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
    skip: "step 4 models NSDataDetector's addresses",
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

  test('a text of more than 4,096 units reads up to its last space at or before its 4,096th unit', () {
    expectLinks(
      '${'x ' * 2047}https://example.com',
      const [],
      apple: [web(4094, 4113, 'https://example.com')],
    );
  });

  test('a text of more than 4,096 units reads up to its last space at or before its 4,096th unit that no phone spans', () {
    expectLinks(
      '${'x ' * 2038}y call +40 712 345 678 now and more words',
      const [],
      apple: [phone(4083, 4098, 'tel:+40712345678')],
    );
  });

  test('a segment links what NSDataDetector reads in its window, from the unit before it to three after it, its stand-ins in that window too', () {
    expectLinks(
      '\u4E2D\u6587 exa\u034Fmple.co\u2061m x',
      const [],
      apple: [web(7, 14, 'http://mple.co')],
    );
  });

  test("a segment's window reads the phones the whole text reads", () {
    expectLinks('call +40 712 345 678x now', [phone(5, 16, 'tel:+40712345')]);
  }, skip: "step 5 models NSDataDetector's phones");

  test("a phone the whole text reads drops the link its segment's window reads over it", () {
    expectLinks(
      '\u0E02\u0E49\u0E2D\u0E21\u0E39\u0E25 ?. sms:+15551234567. //',
      const [],
    );
  }, skip: "step 5 models NSDataDetector's phones");
}
