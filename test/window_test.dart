import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/ux.dart';

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
  const channel = MethodChannel('ux/window/events');

  final listenCalls = <String>[];

  setUp(() {
    listenCalls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      listenCalls.add(call.method);
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
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

  test('a focus event flips focused', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final w = MethodChannelXWindow();
    await pumpEventQueue();
    expect(w.focused.value, isTrue);

    await sendEvent({'type': 'focus', 'focused': false});
    await pumpEventQueue();
    expect(w.focused.value, isFalse);

    await sendEvent({'type': 'focus', 'focused': true});
    await pumpEventQueue();
    expect(w.focused.value, isTrue);
  });
}
