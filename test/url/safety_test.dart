@Skip('the Dart detector does not read the safety rules yet')
library;

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
    expectLinks('see evil.com/\u061Cgood.com x', [
      web(4, 22, 'http://evil.com/\u061Cgood.com'),
    ]);
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

  test('a phone whose text holds a bidi control takes tel: and its text for its URL', () {
    expectLinks('call +1 \u200F555 123 4567 x', [
      phone(5, 21, 'tel:+1 \u200F555 123 4567'),
    ]);
    expectLinks('see +1\u200F5551234567。', [
      phone(4, 17, 'tel:+1\u200F5551234567'),
    ]);
  });

  test('a bidi control outside a link leaves its URL as the link reads', () {
    expectLinks('see \u202Ehttps://evil.com/?moc.knab//:sptth x', [
      web(5, 39, 'https://evil.com/?moc.knab//:sptth'),
    ]);
    expectLinks('call \u200F +1 555 123 4567 x', [
      phone(7, 22, 'tel:+15551234567'),
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
    expectLinks('see https://docs.flutter.dev#setup...? x', [
      web(4, 38, 'https://docs.flutter.dev#setup...?'),
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
