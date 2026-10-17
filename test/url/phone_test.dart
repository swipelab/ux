@Skip('the Dart detector does not read phones yet')
library;

import 'package:flutter_test/flutter_test.dart';

import 'links.dart';

void main() {
  test('the phone shapes NSDataDetector accepts link where their first character is (, + or 0', () {
    expectLinks('call 0712 345 678 now', [phone(5, 17, 'tel:0712345678')]);
    expectLinks('call 0712345678 now', [phone(5, 15, 'tel:0712345678')]);
    expectLinks('call +40 712 345 678 now', [phone(5, 20, 'tel:+40712345678')]);
    expectLinks('call +40-712-345-678 now', [phone(5, 20, 'tel:+40712345678')]);
    expectLinks('call +40.712.345.678 now', [phone(5, 20, 'tel:+40712345678')]);
    expectLinks('call +40/712/345/678 now', [phone(5, 20, 'tel:+40712345678')]);
    expectLinks('call (021) 555-0199 now', [phone(5, 19, 'tel:0215550199')]);
    expectLinks('call (0) 712 345 678 now', [phone(5, 20, 'tel:0712345678')]);
    expectLinks('call +40 (0) 712 345 678 now', [
      phone(5, 24, 'tel:+40712345678'),
    ]);
    expectLinks('call (+40) 712 345 678 now', [
      phone(5, 22, 'tel:+40712345678'),
    ]);
    expectLinks('call 0040 712 345 678 now', [
      phone(5, 21, 'tel:0040712345678'),
    ]);
    expectLinks('call 07 12 34 56 78 now', [phone(5, 19, 'tel:0712345678')]);
    expectLinks('call 0712 345 67 now', [phone(5, 16, 'tel:071234567')]);
    expectLinks('call 030 123456 now', [phone(5, 15, 'tel:030123456')]);
    expectLinks('call +44 20 7946 0958 now', [
      phone(5, 21, 'tel:+442079460958'),
    ]);
    expectLinks('call +81 3-1234-5678 now', [phone(5, 20, 'tel:+81312345678')]);
    expectLinks('call +7 (495) 123-45-67 now', [
      phone(5, 23, 'tel:+74951234567'),
    ]);
    expectLinks('call +1 (555)123-4567 now', [
      phone(5, 21, 'tel:+15551234567'),
    ]);
  });

  test("the phone shapes NSDataDetector rejects don't link", () {
    expectLinks('call 0712.345.678 now', const []);
    expectLinks('call 07123456 now', const []);
    expectLinks('call 0123456 now', const []);
    expectLinks('call 0712 345 now', const []);
    expectLinks('call +4071234 now', const []);
    expectLinks('call +40712345678901234 now', const []);
    expectLinks('call 0 7 1 2 3 4 5 6 7 8 now', const []);
    expectLinks('call 01234567890123456789 now', const []);
    expectLinks('ISBN 978-3-16-148410-0 now', const []);
    expectLinks('card 4111 1111 1111 1111 now', const []);
  });

  test(
    'a word before a number can decide whether NSDataDetector reads a phone',
    () {
      expectLinks('id 0123-4567-8901 now', const []);
      expectLinks('call 0123-4567-8901 now', [
        phone(5, 19, 'tel:012345678901'),
      ]);
      expectLinks('id 0712 345 678 now', const []);
    },
  );

  test("a phone that a '(', '+' or '0' doesn't start gives no link", () {
    expectLinks('call (555) 123-4567 now', [phone(5, 19, 'tel:5551234567')]);
    expectLinks('call 555.123.4567 now', const []);
    expectLinks('call 555-123-4567 now', const []);
    expectLinks('call 5551234567 now', const []);
    expectLinks('pin 12-34-56 or 555-0199', const []);
  });

  test("a phone links at the text's start or after whitespace", () {
    expectLinks('+40 712 345 678', [phone(0, 15, 'tel:+40712345678')]);
    expectLinks('call\u00A0+40 712 345 678 now', [
      phone(5, 20, 'tel:+40712345678'),
    ]);
    expectLinks('call\u3000+40 712 345 678 now', [
      phone(5, 20, 'tel:+40712345678'),
    ]);
    expectLinks('call\u0009+40 712 345 678 now', [
      phone(5, 20, 'tel:+40712345678'),
    ]);
    expectLinks('中文 0712345678', [phone(3, 13, 'tel:0712345678')]);
  });

  test('a phone glued to the character before it gives no link', () {
    expectLinks('call:+40 712 345 678', const []);
    expectLinks('a+40 712 345 678 now', const []);
    expectLinks('中文0712345678', const []);
  });

  test("a phone's first character is an ASCII '(', '+' or '0'", () {
    expectLinks('call ０７１２３４５６７８ now', const []);
    expectLinks('call +４０ ７１２ ３４５ ６７８ now', [phone(5, 20, 'tel:+40712345678')]);
    expectLinks('call ٠٧١٢٣٤٥٦٧٨ now', const []);
  });

  test('a phone with fewer than seven digits gives no link', () {
    expectLinks('call 012345 now', const []);
    expectLinks('call 0123456 now', const []);
  });

  test(
    "a phone's URL is tel: and its digits and '+' up to the first letter",
    () {
      expectLinks('call +1 555 123 4567 now', [
        phone(5, 20, 'tel:+15551234567'),
      ]);
      expectLinks('home 0731098515', [phone(5, 15, 'tel:0731098515')]);
      expectLinks('call (021) 555-0199 today', [
        phone(5, 19, 'tel:0215550199'),
      ]);
    },
  );

  test("a phone's extension stays in its span and out of its URL", () {
    expectLinks(
      'call +1 (555) 123-4567 ext. 89 now',
      [phone(5, 30, 'tel:+15551234567')],
      apple: [phone(5, 30, 'tel:+1555123456789')],
    );
    expectLinks(
      'call +1 555 123 4567 x89 now',
      [phone(5, 24, 'tel:+15551234567')],
      apple: [phone(5, 24, 'tel:+1555123456789')],
    );
    expectLinks(
      'call +40 712 345 678 ext 5 now',
      [phone(5, 26, 'tel:+40712345678')],
      apple: [phone(5, 26, 'tel:+407123456785')],
    );
  });

  test("a '#' and digits after a phone stay out of it", () {
    expectLinks('call 0712 345 678 #5 now', [phone(5, 17, 'tel:0712345678')]);
  });

  test('a letter glued to a phone backs its span off to the group before', () {
    expectLinks('call +40 712 345 678x now', [phone(5, 16, 'tel:+40712345')]);
    expectLinks('call +40 712 345 678a now', [phone(5, 16, 'tel:+40712345')]);
  });

  test("two phones joined by ', ' or ' or ' link apart", () {
    expectLinks('call 0712-345-678, 0712-345-679 now', [
      phone(5, 17, 'tel:0712345678'),
      phone(19, 31, 'tel:0712345679'),
    ]);
    expectLinks('call +40 712 345 678 or +40 712 345 679', [
      phone(5, 20, 'tel:+40712345678'),
      phone(24, 39, 'tel:+40712345679'),
    ]);
  });

  test("a '/' and a digit after a phone stay out of it", () {
    expectLinks('call 0712 345 678/9 now', [phone(5, 17, 'tel:0712345678')]);
  });

  test('a phone ends before trailing punctuation', () {
    expectLinks('call +1-555-123-4567. Then', [
      phone(5, 20, 'tel:+15551234567'),
    ]);
    expectLinks('call +1 555 123 4567, ok', [phone(5, 20, 'tel:+15551234567')]);
  });

  test('a dotted IPv4 shape is a phone where a 0 starts it', () {
    expectLinks('call 044.123.45.67 now', [phone(5, 18, 'tel:0441234567')]);
  });

  test('a phone hides a link inside its span', () {
    expectLinks('call +1 555 10.0.0.1', [phone(5, 20, 'tel:+155510001')]);
    expectLinks('0712 345 678.example.com', [
      web(9, 24, 'http://678.example.com'),
    ]);
  });

  test('dates, times, versions and words read as no phone', () {
    expectLinks('order 2024-10-17 now', const []);
    expectLinks('at 10:30 now', const []);
    expectLinks('v1.2.3.4 now', const []);
    expectLinks('call 1-800-FLOWERS now', const []);
  });
}
