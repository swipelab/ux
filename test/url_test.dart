import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/url.dart';

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
  const channel = MethodChannel('ux/url');

  final calls = <MethodCall>[];

  void answer(Object? Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return handler(call);
    });
  }

  group(
    'XUrl.openAppSettings',
    () {
      setUp(() => calls.clear());

      tearDown(() => messenger.setMockMethodCallHandler(channel, null));

      test('asks the platform to open this app settings page', () async {
        answer((_) => true);

        expect(await XUrl.openAppSettings(), isTrue);
        expect(calls.map((c) => c.method), ['openAppSettings']);
      });

      test('a platform that cannot reach settings answers false', () async {
        answer((_) => false);

        expect(await XUrl.openAppSettings(), isFalse);
      });

      test('a channel failure answers false', () async {
        answer((_) => throw PlatformException(code: 'failed'));

        expect(await XUrl.openAppSettings(), isFalse);
      });

      test('no native handler answers false', () async {
        expect(await XUrl.openAppSettings(), isFalse);
      });
    },
    skip: Platform.isIOS || Platform.isAndroid || Platform.isMacOS
        ? null
        : 'openAppSettings reaches no platform channel on this host',
  );

  group('XUrl.launch on Windows', () {
    setUp(() => calls.clear());

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test(
      'hands the url to ux/url and answers what the platform answers',
      () async {
        answer((_) => true);

        expect(await XUrl.launch('https://example.com/a?b=1'), isTrue);
        expect(calls.single.method, 'launch');
        expect(calls.single.arguments, {'url': 'https://example.com/a?b=1'});
      },
    );
  }, skip: Platform.isWindows ? null : 'the Windows branch runs on Windows');

  group('XUrl.match', () {
    tearDown(() {
      XUrl.debugDetect = null;
      messenger.setMockMethodCallHandler(channel, null);
    });

    test('a bidi isolate stays in the URL of a link the native detector '
        'finds, so XUrl.launch refuses it', () async {
      answer((_) => true);
      const url = 'http://evil.com/\u2067good.com\u2069';
      XUrl.debugDetect = (_) => _wire(const [
        UrlMatch(start: 4, end: 23, url: url, kind: UrlMatchKind.web),
      ]);

      final link = XUrl.match('see evil.com/\u2067good.com\u2069 x').single;
      expect(link.url, url);
      expect(await XUrl.launch(link.url), isFalse);
    });

    test('a bidi isolate stays in the URL of a link the any-scheme pass '
        'finds, so XUrl.launch refuses it', () async {
      answer((_) => true);
      XUrl.debugDetect = (_) => Uint8List(0);

      final link = XUrl.match('see tg://resolve?domain=\u2067evil/good\u2069 x')
          .single;
      expect(link.url, 'tg://resolve?domain=\u2067evil/good\u2069');
      expect(await XUrl.launch(link.url), isFalse);
    });

    test('XUrl.launch refuses a link whose URL holds an Arabic letter '
        'mark', () async {
      answer((_) => true);
      const url = 'http://evil.com/\u061Cgood.com';
      XUrl.debugDetect = (_) => _wire(const [
        UrlMatch(start: 4, end: 22, url: url, kind: UrlMatchKind.web),
      ]);

      final link = XUrl.match('see evil.com/\u061Cgood.com x').single;
      expect(link.url, url);
      expect(await XUrl.launch(link.url), isFalse);
    });

    test('a native link whose text, written with a scheme, holds a bidi '
        'control its URL leaves out takes that text for its URL, so '
        'XUrl.launch refuses it', () async {
      answer((_) => true);
      const darwin = UrlMatch(
        start: 4,
        end: 27,
        url: 'mailto:%D8%9Cops@example.com',
        kind: UrlMatchKind.email,
      );
      XUrl.debugDetect = (_) => _wire(const [darwin]);

      final link = XUrl.match('see mailto:\u061Cops@example.com.').single;
      expect(link.url, 'mailto:\u061Cops@example.com');
      expect(await XUrl.launch(link.url), isFalse);
    });

    test('a native link whose text holds a bidi control its URL leaves out '
        "takes the URL's scheme and then that text for its URL, so "
        'XUrl.launch refuses it', () async {
      answer((_) => true);
      const darwin = UrlMatch(
        start: 5,
        end: 21,
        url: 'tel:+15551234567',
        kind: UrlMatchKind.phone,
      );
      XUrl.debugDetect = (_) => _wire(const [darwin]);

      final link = XUrl.match('call +1 \u200F555 123 4567 x').single;
      expect(link.url, 'tel:+1 \u200F555 123 4567');
      expect(await XUrl.launch(link.url), isFalse);
    });

    test('a link the any-scheme pass finds ends before a C0 or C1 control, '
        'as one the native detector finds does', () {
      const native = [
        UrlMatch(
          start: 4,
          end: 19,
          url: 'https://a.com/x',
          kind: UrlMatchKind.web,
        ),
        UrlMatch(
          start: 20,
          end: 29,
          url: 'http://163.com/1',
          kind: UrlMatchKind.web,
        ),
      ];
      XUrl.debugDetect = (_) => _wire(native);

      expect(XUrl.match('see https://a.com/x\u001F163.com/1 x'), native);
    });

    test("a link's URL leaves out a zero-width space whether the native "
        'detector or the any-scheme pass links it', () {
      const text = '"ftp://a.io/a#\u200B +15551234567';
      const phone = UrlMatch(
        start: 16,
        end: 28,
        url: 'tel:+15551234567',
        kind: UrlMatchKind.phone,
      );
      // darwin's native link ties the any-scheme pass's; Windows' ends before
      // the zero-width space, so the any-scheme pass's longer link is kept.
      _expectMatch(
        text,
        darwin: const [
          UrlMatch(
            start: 1,
            end: 15,
            url: 'ftp://a.io/a#\u200B',
            kind: UrlMatchKind.web,
          ),
          phone,
        ],
        windows: const [
          UrlMatch(
            start: 1,
            end: 14,
            url: 'ftp://a.io/a#',
            kind: UrlMatchKind.web,
          ),
          phone,
        ],
        expected: const [
          UrlMatch(
            start: 1,
            end: 15,
            url: 'ftp://a.io/a#',
            kind: UrlMatchKind.web,
          ),
          phone,
        ],
      );
    });

    test("a scheme link starts after a '_'", () {
      const banlu = UrlMatch(
        start: 1,
        end: 16,
        url: 'banlu://chat/42',
        kind: UrlMatchKind.web,
      );
      _expectMatch(
        '_banlu://chat/42 x',
        darwin: const [banlu],
        windows: const [],
        expected: const [banlu],
      );
    });

    test('a scheme link starts after a digit', () {
      const https = UrlMatch(
        start: 1,
        end: 14,
        url: 'https://a.com',
        kind: UrlMatchKind.web,
      );
      _expectMatch(
        '1https://a.com x',
        darwin: const [
          UrlMatch(
            start: 9,
            end: 14,
            url: 'http://a.com',
            kind: UrlMatchKind.web,
          ),
        ],
        windows: const [https],
        expected: const [https],
      );
    });

    test("a '?' ending a scheme link stays in it", () {
      const tg = UrlMatch(
        start: 0,
        end: 24,
        url: 'tg://resolve?domain=abc?',
        kind: UrlMatchKind.web,
      );
      _expectMatch(
        'tg://resolve?domain=abc?',
        darwin: const [tg],
        windows: const [],
        expected: const [tg],
      );
    });

    test("a '.' before a '?' ending a link stays in it", () {
      const https = UrlMatch(
        start: 4,
        end: 27,
        url: 'https://example.com#a.?',
        kind: UrlMatchKind.web,
      );
      _expectMatch(
        'see https://example.com#a.? y',
        darwin: const [https],
        windows: const [
          UrlMatch(
            start: 4,
            end: 23,
            url: 'https://example.com',
            kind: UrlMatchKind.web,
          ),
        ],
        expected: const [https],
      );
    });

    test("a ')' a scheme link opens stays in it", () {
      const bl = UrlMatch(
        start: 5,
        end: 17,
        url: 'bl://x/a_(b)',
        kind: UrlMatchKind.web,
      );
      _expectMatch(
        '(see bl://x/a_(b)).',
        darwin: const [bl],
        windows: const [],
        expected: const [bl],
      );
    });

    test("a ')' after a link's host ends it", () {
      const docs = UrlMatch(
        start: 1,
        end: 25,
        url: 'https://docs.flutter.dev',
        kind: UrlMatchKind.web,
      );
      _expectMatch(
        '(https://docs.flutter.dev)?',
        darwin: const [docs],
        windows: const [docs],
        expected: const [docs],
      );
    });

    test("a ')' a link does not open ends it with the '?' after it", () {
      const setup = UrlMatch(
        start: 1,
        end: 31,
        url: 'https://docs.flutter.dev#setup',
        kind: UrlMatchKind.web,
      );
      _expectMatch(
        '(https://docs.flutter.dev#setup)?',
        darwin: const [setup],
        windows: const [
          UrlMatch(
            start: 1,
            end: 25,
            url: 'https://docs.flutter.dev',
            kind: UrlMatchKind.web,
          ),
        ],
        expected: const [setup],
      );
    });

    test("a ':' after a link's port ends it", () {
      const server = UrlMatch(
        start: 0,
        end: 20,
        url: 'http://10.0.0.5:8080',
        kind: UrlMatchKind.web,
      );
      _expectMatch(
        'http://10.0.0.5:8080: down',
        darwin: const [server],
        windows: const [server],
        expected: const [server],
      );
    });

    test('a port that ASCII letters follow stays out of a link', () {
      const host = UrlMatch(
        start: 4,
        end: 22,
        url: 'http://example.com',
        kind: UrlMatchKind.web,
      );
      _expectMatch(
        'foo http://example.com:8080abc x',
        darwin: const [host],
        windows: const [host],
        expected: const [host],
      );
    });

    test("a ':' with no port ends a link at its host", () {
      // darwin's native link for this text keeps the ':'.
      const windows = [
        UrlMatch(
          start: 10,
          end: 29,
          url: 'https://example.com',
          kind: UrlMatchKind.web,
        ),
      ];
      XUrl.debugDetect = (_) => _wire(windows);

      expect(XUrl.match('Status at https://example.com: green'), windows);
    });

    test("a scheme and its '://' alone are no link", () {
      XUrl.debugDetect = (_) => Uint8List(0);

      expect(XUrl.match('see https:// y'), const <UrlMatch>[]);
    });

    test("a ':' ending a scheme link's path stays in it", () {
      const banlu = UrlMatch(
        start: 4,
        end: 20,
        url: 'banlu://chat/42:',
        kind: UrlMatchKind.web,
      );
      _expectMatch(
        'see banlu://chat/42: y',
        darwin: const [banlu],
        windows: const [],
        expected: const [banlu],
      );
    });

    test('a host keeps parentheses it opens and closes, two deep', () {
      const https = UrlMatch(
        start: 4,
        end: 24,
        url: 'https://a.com(a(b)c)',
        kind: UrlMatchKind.web,
      );
      _expectMatch(
        'see https://a.com(a(b)c) y',
        darwin: const [https],
        windows: const [
          UrlMatch(
            start: 4,
            end: 17,
            url: 'https://a.com',
            kind: UrlMatchKind.web,
          ),
        ],
        expected: const [https],
      );
    });
  });
}

/// Expects [XUrl.match] of [text] to be [expected] with each platform's
/// native reading of it.
void _expectMatch(
  String text, {
  required List<UrlMatch> darwin,
  required List<UrlMatch> windows,
  required List<UrlMatch> expected,
}) {
  for (final (platform, native) in [('darwin', darwin), ('Windows', windows)]) {
    XUrl.debugDetect = (_) => _wire(native);
    expect(XUrl.match(text), expected, reason: platform);
  }
}

/// [matches] in the native detector's wire layout.
Uint8List _wire(List<UrlMatch> matches) {
  final out = BytesBuilder()..add(_words([matches.length]));
  for (final m in matches) {
    final url = utf8.encode(m.url);
    out
      ..add(_words([m.start, m.end, m.kind.wireByte, url.length]))
      ..add(url);
  }
  return out.toBytes();
}

Uint8List _words(List<int> words) {
  final data = ByteData(words.length * 4);
  for (var i = 0; i < words.length; i++) {
    data.setUint32(i * 4, words[i], Endian.little);
  }
  return data.buffer.asUint8List();
}
