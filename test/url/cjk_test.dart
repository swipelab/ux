@Skip('the Dart detector does not read unspaced-script text yet')
library;

import 'package:flutter_test/flutter_test.dart';

import 'links.dart';

void main() {
  test('a link ends before CJK punctuation', () {
    expectLinks('看 https://example.com/a?b=1。下一句', [
      web(2, 27, 'https://example.com/a?b=1'),
    ]);
    expectLinks('看 https://example.com。下一句', [
      web(2, 21, 'https://example.com'),
    ]);
    expectLinks('链接：example.com/a。下', [web(3, 16, 'http://example.com/a')]);
    expectLinks('see https://example.com/a」x', [
      web(4, 25, 'https://example.com/a'),
    ]);
  });

  test('a bare domain glued after unspaced-script letters leaves them out', () {
    expectLinks('访问example.com，然后', [web(2, 13, 'http://example.com')]);
    expectLinks('访问banlu.app/x', [web(2, 13, 'http://banlu.app/x')]);
    expectLinks('ข้อมูลที่example.com', [web(9, 20, 'http://example.com')]);
    expectLinks('ຂໍ້ມູນexample.com', [web(6, 17, 'http://example.com')]);
    expectLinks('មើលexample.com', [web(3, 14, 'http://example.com')]);
    expectLinks('ကြည့်example.com', [web(5, 16, 'http://example.com')]);
    expectLinks('한국어example.com', [web(3, 14, 'http://example.com')]);
    expectLinks('ㄅㄆexample.com', [web(2, 13, 'http://example.com')]);
  });

  test('unspaced-script letters glued after a bare domain stay out of it', () {
    expectLinks('example.com然后', [web(0, 11, 'http://example.com')]);
    expectLinks('访问example.com和google.com', [
      web(2, 13, 'http://example.com'),
      web(14, 24, 'http://google.com'),
    ]);
  });

  test('a bare domain leaves out a period and the unspaced-script letters after it', () {
    expectLinks('请看example.com.谢谢', [web(2, 13, 'http://example.com')]);
    expectLinks('see example.com.谢谢.dev/a x', [
      web(4, 15, 'http://example.com'),
    ]);
  });

  test('a letter a period glues to a bare domain glued after CJK letters makes it no link', () {
    expectLinks('访问example.com.Then', const []);
    expectLinks('访问example.com.Then/a', const []);
    expectLinks('访问 example.com.Then/a', const []);
    expectLinks('访问example.com. Then', [web(2, 13, 'http://example.com')]);
  });

  test("a scheme link's host ends before unspaced-script letters inside its last label", () {
    expectLinks(
      'http://example.com然后',
      [web(0, 18, 'http://example.com')],
      apple: [web(0, 20, 'http://example.com然后')],
    );
    expectLinks(
      'see http://example.comข้อมูล x',
      [web(4, 22, 'http://example.com')],
      apple: [web(4, 28, 'http://example.comข้อมูล')],
    );
    expectLinks(
      'see bl://x然后 y',
      [web(4, 10, 'bl://x')],
      apple: [web(4, 12, 'bl://x然后')],
    );
  });

  test("a scheme link's path keeps unspaced-script letters, and its port ends before them", () {
    expectLinks('see https://zh.wikipedia.org/wiki/中文 x', [
      web(4, 36, 'https://zh.wikipedia.org/wiki/中文'),
    ]);
    expectLinks('http://example.com:8080然后', [
      web(0, 23, 'http://example.com:8080'),
    ]);
  });

  test('a format character after unspaced-script letters starts a bare host after it', () {
    expectLinks('ข้อมูล\u200Bexample.com', [web(7, 18, 'http://example.com')]);
    expectLinks('ข้อมูล\u2060example.com', [
      web(7, 18, 'http://example.com'),
    ], apple: const []);
    expectLinks('ข้อมูล\u200Dexample.com', [
      web(7, 18, 'http://example.com'),
    ], apple: const []);
    expectLinks('ข้อมูล\u200Cexample.com', [
      web(7, 18, 'http://example.com'),
    ], apple: const []);
    expectLinks('ข้อมูล\u200B10.0.0.1 x', [
      web(7, 15, 'http://10.0.0.1'),
    ], apple: const []);
    expectLinks('中文\u2060example.com', [web(3, 14, 'http://example.com')]);
  });

  test('a bidi control before a bare host stays outside it', () {
    expectLinks('see \u202Eexample.com', [web(5, 16, 'http://example.com')]);
    expectLinks('ข้อมูล\u200B\u202Eexample.com', [
      web(8, 19, 'http://example.com'),
    ]);
  });

  test("a match past a fullwidth parenthesis that continues a link's path is no link of its own", () {
    expectLinks('https://example.com/路径（1）/page.html', [
      web(0, 22, 'https://example.com/路径'),
    ]);
    expectLinks('https://example.com/a（1）/page.com', [
      web(0, 21, 'https://example.com/a'),
    ]);
    expectLinks('https://example.com/a（1）/page.html?x=1', [
      web(0, 21, 'https://example.com/a'),
    ]);
    expectLinks('https://example.com/a.（1）/page.com', [
      web(0, 21, 'https://example.com/a'),
    ]);
    expectLinks('https://example.com/a（1）/www.example.org/x', [
      web(0, 21, 'https://example.com/a'),
    ]);
    expectLinks('https://example.com/a（1）?q=example.org', [
      web(0, 21, 'https://example.com/a'),
    ]);
    expectLinks('https://example.com#a（1）/page.com', [
      web(0, 21, 'https://example.com#a'),
    ]);
  });

  test(
    "an email's path past a fullwidth parenthesis is no link of its own",
    () {
      expectLinks('a@example.com/x（1）/page.com', [
        email(0, 13, 'mailto:a@example.com'),
      ]);
    },
  );

  test(
    'a bare domain past CJK punctuation links where no path continues to it',
    () {
      expectLinks('https://example.com/a，/example.org', [
        web(0, 21, 'https://example.com/a'),
        web(23, 34, 'http://example.org'),
      ]);
      expectLinks('https://example.com/a（1）。/example.org', [
        web(0, 21, 'https://example.com/a'),
        web(26, 37, 'http://example.org'),
      ]);
      expectLinks('https://example.com/a）/page.com', [
        web(0, 21, 'https://example.com/a'),
        web(23, 31, 'http://page.com'),
      ]);
      expectLinks('https://example.com/a，备用:example.org', [
        web(0, 21, 'https://example.com/a'),
        web(25, 36, 'http://example.org'),
      ]);
      expectLinks('https://example.com/a（1） see/example.org', [
        web(0, 21, 'https://example.com/a'),
        web(29, 40, 'http://example.org'),
      ]);
      expectLinks('https://example.com/a，#话题#example.org', [
        web(0, 21, 'https://example.com/a'),
        web(26, 37, 'http://example.org'),
      ]);
      expectLinks('https://example.com/a，和/或example.org', [
        web(0, 21, 'https://example.com/a'),
        web(25, 36, 'http://example.org'),
      ]);
      expectLinks('https://example.com/a，例如a/b,example.org', [
        web(0, 21, 'https://example.com/a'),
        web(28, 39, 'http://example.org'),
      ]);
    },
  );

  test("a scheme link's host ends before fullwidth punctuation", () {
    expectLinks('https://example.com（x）/page.com', [
      web(0, 19, 'https://example.com'),
      web(23, 31, 'http://page.com'),
    ]);
  });

  test(
    "a vertical bar ends a bare domain's path and a bare domain after it links",
    () {
      expectLinks('see example.com/a|example.org/b z', [
        web(4, 17, 'http://example.com/a'),
        web(18, 31, 'http://example.org/b'),
      ]);
    },
  );
}
