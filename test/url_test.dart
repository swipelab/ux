import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/url.dart';

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
  const channel = MethodChannel('ux/url');

  final calls = <MethodCall>[];

  group('XUrl.openAppSettings', () {
    setUp(() => calls.clear());

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    void answer(Object? Function(MethodCall call) handler) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return handler(call);
      });
    }

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
          : 'XUrl reaches no platform channel on this host');
}
