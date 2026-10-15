import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/window.dart';

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
  const channel = MethodChannel('ux/window/events');
  const methods = MethodChannel('ux/window');

  final listenCalls = <String>[];
  final methodCalls = <MethodCall>[];

  setUp(() {
    listenCalls.clear();
    methodCalls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      listenCalls.add(call.method);
      return null;
    });
    messenger.setMockMethodCallHandler(methods, (call) async {
      methodCalls.add(call);
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(methods, null);
    debugDefaultTargetPlatformOverride = null;
  });

  Future<void> sendEvent(Object? event) => messenger.handlePlatformMessage(
    'ux/window/events',
    const StandardMethodCodec().encodeSuccessEnvelope(event),
    (_) {},
  );

  // Regression: iOS has no native handler, so activating the broadcast
  // stream throws MissingPluginException straight to FlutterError.onError.
  test('iOS does not activate the events channel', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final w = MethodChannelXWindow();
    await pumpEventQueue();
    expect(listenCalls, isEmpty);
    expect(w.focused.value, isTrue);
  });

  test('Android activates the events channel', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    MethodChannelXWindow();
    await pumpEventQueue();
    expect(listenCalls, contains('listen'));
  });

  test(
    'Windows activates the events channel, whose focus event flips focused',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final w = MethodChannelXWindow();
      await pumpEventQueue();
      expect(listenCalls, contains('listen'));
      expect(w.focused.value, isTrue);

      await sendEvent({'type': 'focus', 'focused': false});
      await pumpEventQueue();
      expect(w.focused.value, isFalse);

      await sendEvent({'type': 'focus', 'focused': true});
      await pumpEventQueue();
      expect(w.focused.value, isTrue);
    },
  );

  for (final platform in [
    TargetPlatform.iOS,
    TargetPlatform.android,
    TargetPlatform.macOS,
    TargetPlatform.windows,
  ]) {
    test('keepAwake reaches the platform on ${platform.name}', () async {
      debugDefaultTargetPlatformOverride = platform;
      final w = MethodChannelXWindow();
      await pumpEventQueue();

      await w.keepAwake(true);
      await w.keepAwake(false);

      expect(methodCalls.map((c) => c.method), ['keepAwake', 'keepAwake']);
      expect(methodCalls.first.arguments, {'enabled': true});
      expect(methodCalls.last.arguments, {'enabled': false});
    });
  }

  test('keepAwake is a no-op where no plugin serves it', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final w = MethodChannelXWindow();
    await pumpEventQueue();

    await w.keepAwake(true);

    expect(methodCalls, isEmpty);
  });

  test('a platform failure leaves keepAwake resolved', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    messenger.setMockMethodCallHandler(methods, (call) async {
      throw PlatformException(code: 'keep_awake_failed');
    });
    final w = MethodChannelXWindow();
    await pumpEventQueue();

    await expectLater(w.keepAwake(true), completes);
  });
}
