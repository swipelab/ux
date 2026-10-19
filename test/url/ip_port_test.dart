import 'package:flutter_test/flutter_test.dart';

import 'links.dart';

void main() {
  test('a bare IPv4 address links whatever its digit count', () {
    expectLinks('ip 10.0.0.1 x', [web(3, 11, 'http://10.0.0.1')]);
    expectLinks('ip 192.168.1.1 x', [web(3, 14, 'http://192.168.1.1')]);
  });

  test('a bare IPv4 address links with a port and a path', () {
    expectLinks('see 10.0.0.1:8080/a x', [
      web(4, 19, 'http://10.0.0.1:8080/a'),
    ]);
  });

  test(
    'a bare IPv4 address glued between unspaced-script letters leaves them out',
    () {
      expectLinks('访问192.168.1.1然后', [web(2, 13, 'http://192.168.1.1')]);
    },
  );

  test('a bare IPv4 address glued to letters gives no link', () {
    expectLinks('abc10.0.0.1 x', const []);
    expectLinks('x192.168.1.1 x', const []);
    expectLinks('é10.0.0.1/x', const []);
  });

  test('two bare IPv4 addresses in a row link apart', () {
    expectLinks('192.168.1.1 10.0.0.2', [
      web(0, 11, 'http://192.168.1.1'),
      web(12, 20, 'http://10.0.0.2'),
    ]);
  });

  test("a bare IPv4 address after a '+1' is a web link", () {
    expectLinks('ip +1 192.168.1.1 x', [web(6, 17, 'http://192.168.1.1')]);
  });

  test('a dotted number with an octet over 255 gives no link', () {
    expectLinks('256.1.1.1/x', const []);
  });

  test('a dotted run of five numbers gives no link', () {
    expectLinks('1.2.3.4.5/x', const [], apple: [web(0, 7, 'http://1.2.3.4')]);
    expectLinks(
      'see 1.2.3.4.5 x',
      const [],
      apple: [web(4, 11, 'http://1.2.3.4')],
    );
  });

  test("a final '.' after a bare IPv4 address is punctuation", () {
    expectLinks('see 1.1.1.1. x', [web(4, 11, 'http://1.1.1.1')]);
  });

  test('a dotted run of three numbers gives no link', () {
    expectLinks('see 1.2.3 x', const []);
  });

  test('a bare dotted quad with a leading-zero octet gives no web link', () {
    expectLinks(
      'ip 010.168.1.1 x',
      const [],
      apple: [web(3, 14, 'http://010.168.1.1')],
    );
    expectLinks(
      '(044.168.1.1)',
      const [],
      apple: [web(1, 12, 'http://044.168.1.1')],
    );
    expectLinks(
      '访问010.0.0.1然后',
      const [],
      apple: [web(2, 11, 'http://010.0.0.1')],
    );
    expectLinks('see 007.com x', [web(4, 11, 'http://007.com')]);
  });

  test('a bare IPv6 address gives no link', () {
    expectLinks('see [2001:db8::1] x', const []);
    expectLinks('see 2001:db8::1 x', const []);
  });

  test('an IP literal after a scheme links', () {
    expectLinks('see http://[::1] x', [web(4, 16, 'http://[::1]')]);
    expectLinks('see http://[fe80::1%25en0]/ x', [
      web(4, 27, 'http://[fe80::1%25en0]/'),
    ]);
    expectLinks('see http://[v1.fe80::a+en1]/ x', [
      web(4, 28, 'http://[v1.fe80::a+en1]/'),
    ]);
  });

  test("an IP literal and a port before '@' read as a userinfo", () {
    expectLinks('http://[::1]:80@b', [web(0, 17, 'http://[::1]:80@b')]);
  });

  test('a bare domain takes a port of one to five digits', () {
    expectLinks('see example.com:8 x', [web(4, 17, 'http://example.com:8')]);
    expectLinks('see example.com:65536 x', [
      web(4, 21, 'http://example.com:65536'),
    ]);
    expectLinks('see example.com:123456 x', [web(4, 15, 'http://example.com')]);
  });

  test('a bare domain keeps a port of ASCII digits that unspaced-script letters follow', () {
    expectLinks('example.com:8080ข้อมูล', [
      web(0, 16, 'http://example.com:8080'),
    ]);
    expectLinks('访问example.com:8080然后', [
      web(2, 18, 'http://example.com:8080'),
    ]);
  });

  test(
    "a bare domain's port that ASCII letters follow stays out of the link",
    () {
      expectLinks('访问example.com:8080abc然后', [
        web(2, 13, 'http://example.com'),
      ]);
    },
  );

  test("a bare domain's port of other decimal digits ends at a boundary", () {
    expectLinks('see example.com:٣', [web(4, 17, 'http://example.com:٣')]);
    expectLinks('访问example.com:8080٣然后', [web(2, 13, 'http://example.com')]);
    expectLinks('see example.com:8080٣ y', [
      web(4, 21, 'http://example.com:8080٣'),
    ]);
  });

  test('a fullwidth-digit port reads as its ASCII digits', () {
    expectLinks(
      'see example.com:８０ x',
      [web(4, 18, 'http://example.com:80')],
      apple: [web(4, 18, 'http://example.com:８０')],
    );
    expectLinks(
      '访问example.com:８０然后',
      [web(2, 16, 'http://example.com:80')],
      apple: [web(2, 13, 'http://example.com')],
    );
    expectLinks(
      'see http://example.com:８０/x y',
      [web(4, 27, 'http://example.com:80/x')],
      apple: [web(4, 27, 'http://example.com:８０/x')],
    );
  });

  test("a scheme link's port runs to its digits, whatever their value", () {
    expectLinks('see http://example.com:65536/x x', [
      web(4, 30, 'http://example.com:65536/x'),
    ]);
    expectLinks('see http://example.com:123456/x x', [
      web(4, 31, 'http://example.com:123456/x'),
    ]);
  });

  test(
    "a scheme link's port that ASCII letters follow stays out of the link",
    () {
      expectLinks('see http://example.com:8080abc x', [
        web(4, 22, 'http://example.com'),
      ]);
    },
  );

  test(
    "a scheme link's port that a non-ASCII letter or digit follows stays in it",
    () {
      expectLinks('see https://a.com:8080é y', [
        web(4, 22, 'https://a.com:8080'),
      ]);
      expectLinks('éhttps://a.com:8080٣', [web(1, 19, 'https://a.com:8080')]);
    },
  );

  test("a scheme link's port that '.' and a TLD follow ends the link", () {
    expectLinks('see http://example.com:8080.com/x y', [
      web(4, 27, 'http://example.com:8080'),
    ]);
    expectLinks('see http://example.com:8080.com y', [
      web(4, 27, 'http://example.com:8080'),
    ]);
  });

  test("a ':' after a port ends the link", () {
    expectLinks('Server http://10.0.0.5:8080: down', [
      web(7, 27, 'http://10.0.0.5:8080'),
    ]);
    expectLinks('https://example.com:443: ok', [
      web(0, 23, 'https://example.com:443'),
    ]);
  });

  test("an empty port keeps its ':'", () {
    expectLinks('Status at https://example.com: green', [
      web(10, 30, 'https://example.com:'),
    ]);
    expectLinks('see bl://x: y', [web(4, 11, 'bl://x:')]);
  });
}
