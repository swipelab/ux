import 'dart:io';

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
}
