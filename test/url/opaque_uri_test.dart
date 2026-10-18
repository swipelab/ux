@Skip('the Dart detector does not read opaque URIs yet')
library;

import 'package:flutter_test/flutter_test.dart';

import 'links.dart';

void main() {
  test(
    'an opaque URI on the list links as a web link whose URL is its text',
    () {
      expectLinks('see sms:abc now', [web(4, 11, 'sms:abc')]);
      expectLinks('see tel:abc now', [web(4, 11, 'tel:abc')]);
      expectLinks('see callto:abc now', [web(4, 14, 'callto:abc')]);
      expectLinks('see maps:abc now', [web(4, 12, 'maps:abc')]);
      expectLinks('see xmpp:abc now', [web(4, 12, 'xmpp:abc')]);
      expectLinks('see sip:abc now', [web(4, 11, 'sip:abc')]);
      expectLinks('see im:abc now', [web(4, 10, 'im:abc')]);
      expectLinks('see aim:abc now', [web(4, 11, 'aim:abc')]);
      expectLinks('see jabber:abc now', [web(4, 14, 'jabber:abc')]);
      expectLinks('see news:abc now', [web(4, 12, 'news:abc')]);
      expectLinks('see cid:abc now', [web(4, 11, 'cid:abc')]);
      expectLinks('see feed:abc now', [web(4, 12, 'feed:abc')]);
      expectLinks('see itms:abc now', [web(4, 12, 'itms:abc')]);
      expectLinks('see skype:abc now', [web(4, 13, 'skype:abc')]);
      expectLinks('see webcal:abc now', [web(4, 14, 'webcal:abc')]);
    },
  );

  test('an opaque URI off the list does not link', () {
    expectLinks('see spotify:abc now', const []);
    expectLinks('see geo:abc now', const []);
    expectLinks('see magnet:abc now', const []);
    expectLinks('see bitcoin:abc now', const []);
    expectLinks('see about:abc now', const []);
    expectLinks('see data:abc now', const []);
    expectLinks('see javascript:abc now', const []);
  });

  test('an opaque URI takes any non-empty body of URL characters', () {
    expectLinks('see sms:é now', [web(4, 9, 'sms:é')]);
    expectLinks('see sms:a b now', [web(4, 9, 'sms:a')]);
    expectLinks('see sms: now', const []);
  });

  test("an opaque URI's scheme in any case links as written", () {
    expectLinks('text SMS:+15551234567 now', [web(5, 21, 'SMS:+15551234567')]);
  });

  test(
    "an opaque URI starts at a word start or after a '_' at the text's start",
    () {
      expectLinks('_tel:+15551234567', [web(1, 17, 'tel:+15551234567')]);
      expectLinks('see _sms:abc now', const []);
      expectLinks('see 1sms:abc now', const []);
    },
  );

  test('a written sms: URI links as itself', () {
    expectLinks('text sms:+15551234567 now', [web(5, 21, 'sms:+15551234567')]);
    expectLinks('text sms:+1-555-123-4567 now', [
      web(5, 24, 'sms:+1-555-123-4567'),
    ]);
  });

  test('a written tel: URI links as itself, with no phone inside it', () {
    expectLinks('call tel:+15551234567 now', [
      web(5, 21, 'tel:+15551234567'),
    ], apple: const []);
    expectLinks('call tel:+1-555-123-4567 now', [
      web(5, 24, 'tel:+1-555-123-4567'),
    ], apple: const []);
    expectLinks('see TEL:+15551234567 x', [
      web(4, 20, 'TEL:+15551234567'),
    ], apple: const []);
    expectLinks('see tel:+15551234567 now', [web(4, 20, 'tel:+15551234567')]);
    expectLinks('call tel:555 now', [web(5, 12, 'tel:555')]);
  });

  test(
    'a scheme off the opaque list with an email after it links the email',
    () {
      expectLinks(
        'see facetime:user@example.com now',
        [email(13, 29, 'mailto:user@example.com')],
        apple: [web(18, 29, 'http://example.com')],
      );
      expectLinks('see xmpp:user@example.com now', [
        web(4, 25, 'xmpp:user@example.com'),
      ]);
    },
  );

  test('a scheme with no slashes before a bare host links the host', () {
    expectLinks('see http:example.com now', [web(9, 20, 'http://example.com')]);
  });

  test('mailto: takes an address as an email', () {
    expectLinks('see MAILTO:ops@example.com now', [
      email(4, 26, 'MAILTO:ops@example.com'),
    ]);
    expectLinks('see mailto:abc now', const []);
  });

  test('mailto:// links as an email', () {
    expectLinks('see mailto://a.io/a now', [email(4, 19, 'mailto://a.io/a')]);
    expectLinks("see mailto://a.io/a'", [email(4, 20, "mailto://a.io/a'")]);
  });

  test("a mailto: after a '_' links its address as an email", () {
    expectLinks(
      '_mailto:a@b.com',
      [email(8, 15, 'mailto:a@b.com')],
      apple: [web(10, 15, 'http://b.com')],
    );
  });

  test(
    'a webcal:// URI whose host NSDataDetector reads as nothing does not link',
    () {
      expectLinks(
        'webcal://10.0.0.1.١٢',
        const [],
        apple: [web(0, 20, 'webcal://10.0.0.1.١٢')],
      );
      expectLinks(
        'webcal://+15551234567.١٢',
        const [],
        apple: [web(0, 24, 'webcal://+15551234567.١٢')],
      );
      expectLinks(
        'webcal://256.1.1.1.١٢',
        const [],
        apple: [web(0, 21, 'webcal://256.1.1.1.١٢')],
      );
    },
  );

  test('a webcal:// URI whose host NSDataDetector reads links', () {
    expectLinks('webcal://a.١٢', [web(0, 13, 'webcal://a.١٢')]);
    expectLinks('webcal://256.1.1.1', [web(0, 18, 'webcal://256.1.1.1')]);
    expectLinks('sms://10.0.0.1.١٢', [web(0, 17, 'sms://10.0.0.1.١٢')]);
  });
}
