import 'package:flutter_test/flutter_test.dart';

import 'links.dart';

void main() {
  test("a bidi isolate stays in a native link's URL", () {
    expectLinks('see evil.com/\u2067good.com\u2069 x', [
      web(4, 23, 'http://evil.com/\u2067good.com\u2069'),
    ]);
    expectLinks('see https://\u2067evil.com/good.com\u2069 x', [
      web(4, 31, 'https://\u2067evil.com/good.com\u2069'),
    ]);
  });

  test("a bidi isolate stays in an any-scheme link's URL", () {
    expectLinks('see tg://resolve?domain=\u2067evil/good\u2069 x', [
      web(4, 35, 'tg://resolve?domain=\u2067evil/good\u2069'),
    ]);
  });

  test("an Arabic letter mark stays in a link's URL", () {
    expectLinks('https://例え.jp/パ\u061Cス)', [
      web(0, 17, 'https://例え.jp/パ\u061Cス'),
    ]);
    expectLinks('see https://example.com/a\u061Cb x', [
      web(4, 27, 'https://example.com/a\u061Cb'),
    ]);
  });

  test('an email whose text holds a bidi control takes its scheme and its text for its URL', () {
    expectLinks('see mailto:\u061Cops@example.com.', [
      email(4, 27, 'mailto:\u061Cops@example.com'),
    ]);
    expectLinks('mail ops\u061C@example.com.', [
      email(5, 21, 'mailto:ops\u061C@example.com'),
    ]);
    expectLinks('(mailto:ops\u200E@example.com.', [
      email(1, 24, 'mailto:ops\u200E@example.com'),
    ]);
    expectLinks('see ops@examp\u061Cle.com,', [
      email(4, 20, 'mailto:ops@examp\u061Cle.com'),
    ]);
  });

  test("a bidi control before an address's first character or after its last stays outside it", () {
    expectLinks('see \u202Eops@example.com x', [
      email(5, 20, 'mailto:ops@example.com'),
    ]);
    expectLinks('see \u2066ops@example.com\u2069 x', [
      email(5, 20, 'mailto:ops@example.com'),
    ]);
  });

  test('a bidi control outside a link leaves its URL as the link reads', () {
    expectLinks('see \u202Ehttps://evil.com/?moc.knab//:sptth x', [
      web(5, 39, 'https://evil.com/?moc.knab//:sptth'),
    ]);
  });

  test('a C0 or C1 control or DEL ends a link', () {
    expectLinks('see https://a.com/x\u001F163.com/1 x', [
      web(4, 19, 'https://a.com/x'),
      web(20, 29, 'http://163.com/1'),
    ]);
    expectLinks('see https://a.com/x\u0085163.com/1 x', [
      web(4, 19, 'https://a.com/x'),
      web(20, 29, 'http://163.com/1'),
    ]);
    expectLinks('see https://a.com/x\u007Fy x', [
      web(4, 19, 'https://a.com/x'),
    ]);
  });

  test("a control after a link takes a trailing '&' with it", () {
    expectLinks('see sms:a=b&\u0001 x', [web(4, 11, 'sms:a=b')]);
  });

  test("a control after a link takes only the last of two '/' with it", () {
    expectLinks('see sms:ab//\u0001 x', [web(4, 11, 'sms:ab/')]);
  });

  test(
    "a private-use character outside NSDataDetector's stops stays in a link",
    () {
      expectLinks('see sms:ab\uF7FFc x', [web(4, 12, 'sms:ab\uF7FFc')]);
    },
  );

  test("an opaque URI whose body a control leaves without a character in \\w is no link", () {
    expectLinks('see sms:+\u0001 x', const []);
  });

  test('a C0 or C1 control inside a host splits it into two links', () {
    expectLinks('https://exam\u009Fple.com/a?b=1', [
      web(0, 12, 'https://exam'),
      web(13, 26, 'http://ple.com/a?b=1'),
    ]);
    expectLinks('see htt\u0005ps://e\u007Fxample.com/a?b=1 x', [
      web(8, 14, 'ps://e'),
      web(15, 31, 'http://xample.com/a?b=1'),
    ]);
  });

  test(
    "a link's host ends before trailing marks that a '?' or ':' follows",
    () {
      expectLinks(
        'Did you mean https://example.com...? ok',
        [web(13, 32, 'https://example.com')],
        apple: [web(13, 36, 'https://example.com...?')],
      );
      expectLinks(
        'Is it really https://example.com!?',
        [web(13, 32, 'https://example.com')],
        apple: [web(13, 34, 'https://example.com!?')],
      );
      expectLinks(
        'see https://example.com!?q x',
        [web(4, 23, 'https://example.com')],
        apple: [web(4, 26, 'https://example.com!?q')],
      );
      expectLinks(
        'see bl://x...? y',
        [web(4, 10, 'bl://x')],
        apple: [web(4, 14, 'bl://x...?')],
      );
      expectLinks(
        'see https://example.com.: x',
        [web(4, 23, 'https://example.com')],
        apple: [web(4, 25, 'https://example.com.:')],
      );
    },
  );

  test("marks before a trailing '?' after a path, query or fragment stay", () {
    expectLinks('see https://example.com#a...? x', [
      web(4, 29, 'https://example.com#a...?'),
    ]);
  });

  test('a format character inside a word starts no bare host', () {
    expectLinks(
      'see exam\u200Bple.com x',
      const [],
      apple: [web(9, 16, 'http://ple.com')],
    );
    expectLinks(
      '123\u200Bexample.com',
      const [],
      apple: [web(4, 15, 'http://example.com')],
    );
    expectLinks('1\u2060example.com x', const []);
  });
}
