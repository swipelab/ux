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
      const native = {
        'darwin': [
          UrlMatch(
            start: 1,
            end: 15,
            url: 'ftp://a.io/a#\u200B',
            kind: UrlMatchKind.web,
          ),
          phone,
        ],
        'Windows': [
          UrlMatch(
            start: 1,
            end: 14,
            url: 'ftp://a.io/a#',
            kind: UrlMatchKind.web,
          ),
          phone,
        ],
      };
      for (final MapEntry(key: platform, value: matches) in native.entries) {
        XUrl.debugDetect = (_) => _wire(matches);
        expect(XUrl.match(text), const [
          UrlMatch(
            start: 1,
            end: 15,
            url: 'ftp://a.io/a#',
            kind: UrlMatchKind.web,
          ),
          phone,
        ], reason: platform);
      }
    });
  });
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
