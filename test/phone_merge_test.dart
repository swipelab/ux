import 'package:flutter_test/flutter_test.dart';
import 'package:ux/src/url/detect.dart';
import 'package:ux/src/url/phones.dart';
import 'package:ux/url.dart';

UrlMatch _web(int start, int end, String url) =>
    UrlMatch(start: start, end: end, url: url, kind: UrlMatchKind.web);

UrlMatch _email(int start, int end, String url) =>
    UrlMatch(start: start, end: end, url: url, kind: UrlMatchKind.email);

UrlMatch _phone(int start, int end, String url) =>
    UrlMatch(start: start, end: end, url: url, kind: UrlMatchKind.phone);

/// The links of [text] with [phones], the platform's reading of it.
List<UrlMatch> _merged(String text, List<PlatformPhone> phones) =>
    withPhones(text, detectLinks(text), (_, _) => phones);

void main() {
  test("a phone joins where it starts after a space with an ASCII '(', '+' "
      "or '0'", () {
    expect(
      _merged('call 555 123 4567 or +40 712 345 678', [
        (start: 5, end: 17, phone: '555 123 4567'),
        (start: 21, end: 36, phone: '+40 712 345 678'),
      ]),
      [_phone(21, 36, 'tel:+40712345678')],
    );
    expect(
      _merged('order-0712345678 or (555) 123-4567', [
        (start: 6, end: 16, phone: '0712345678'),
        (start: 20, end: 34, phone: '(555) 123-4567'),
      ]),
      [_phone(20, 34, 'tel:5551234567')],
    );
  });

  test('a phone whose number holds fewer than seven digits goes', () {
    expect(
      _merged('call +1 07972 or +1 555 123 4567 now', [
        (start: 5, end: 13, phone: '+1 07972'),
        (start: 17, end: 32, phone: '+1 555 123 4567'),
      ]),
      [_phone(17, 32, 'tel:+15551234567')],
    );
  });

  test("an extension stays in a phone's span and out of its URL", () {
    expect(
      _merged('call +1 (555) 123-4567 ext. 89 now', [
        (start: 5, end: 30, phone: '+1 (555) 123-4567;89'),
      ]),
      [_phone(5, 30, 'tel:+15551234567')],
    );
    expect(
      _merged('call +1 555 123 4567 x89 now', [
        (start: 5, end: 24, phone: '+1 555 123 4567 x89'),
      ]),
      [_phone(5, 24, 'tel:+15551234567')],
    );
  });

  test('a phone whose text holds an invisible space goes', () {
    expect(
      _merged('call +1 555 123 4567 now', [
        (start: 5, end: 20, phone: '+1 555 123 4567'),
      ]),
      const <UrlMatch>[],
    );
  });

  test('a phone over a Dart link goes, and the link stays', () {
    expect(
      _merged('ip +1 192.168.1.1 x', [
        (start: 3, end: 17, phone: '+1 192.168.1.1'),
      ]),
      [_web(6, 17, 'http://192.168.1.1')],
    );
    expect(
      _merged('call +1 555 10.0.0.1', [
        (start: 5, end: 20, phone: '+1 555 10.0.0.1'),
      ]),
      [_web(12, 20, 'http://10.0.0.1')],
    );
  });

  test('a phone joins the links in order of start', () {
    expect(
      _merged(
        'see https://example.com/a?b=1, mail ops@example.com or call '
        '+40 712 345 678',
        [(start: 60, end: 75, phone: '+40 712 345 678')],
      ),
      [
        _web(4, 29, 'https://example.com/a?b=1'),
        _email(36, 51, 'mailto:ops@example.com'),
        _phone(60, 75, 'tel:+40712345678'),
      ],
    );
  });

  test('a phone whose text holds a bidi control takes its text for its '
      'URL', () {
    expect(
      _merged('see +1‏5551234567。', [
        (start: 4, end: 17, phone: '+1‏5551234567'),
      ]),
      [_phone(4, 17, 'tel:+1‏5551234567')],
    );
  });

  test('a text keeps at most 64 phones', () {
    final text = List.filled(70, '+40712345678').join(' ');
    final links = _merged(text, [
      for (var i = 0; i < 70; i++)
        (start: i * 13, end: i * 13 + 12, phone: '+40712345678'),
    ]);
    expect(links, hasLength(maxPhones));
    expect(links.last, _phone(63 * 13, 63 * 13 + 12, 'tel:+40712345678'));
  });

  test('the platform reads the units a long text reads, and a phone that '
      'ends where they end goes', () {
    final text = '${'x ' * 2043}+40712345 678';
    final read = <int>[];
    final links = withPhones(text, detectLinks(text), (_, length) {
      read.add(length);
      return [(start: 4086, end: 4095, phone: '+40712345')];
    });
    expect(read, [4095]);
    expect(links, const <UrlMatch>[]);
  });

  test("the platform reads a text only where an ASCII '(', '+' or '0' "
      'starts a word and it holds seven ASCII or fullwidth digits', () {
    expect(mayHoldPhone('call 555 123 4567 now'), isFalse);
    expect(mayHoldPhone('call +1 234 56 now'), isFalse);
    expect(mayHoldPhone('call +40 712 345 678 now'), isTrue);
    expect(
      mayHoldPhone(
        'call +４０ ７１２ ３４５ '
        '６７８ now',
      ),
      isTrue,
    );
  });
}
