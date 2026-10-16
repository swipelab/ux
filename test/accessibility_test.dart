import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/accessibility.dart';

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
  const events = MethodChannel('ux/accessibility/events');

  final listenCalls = <String>[];

  setUp(() {
    listenCalls.clear();
    messenger.setMockMethodCallHandler(events, (call) async {
      listenCalls.add(call.method);
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(events, null);
    debugDefaultTargetPlatformOverride = null;
  });

  Future<void> sendEvent(Object? event) => messenger.handlePlatformMessage(
    'ux/accessibility/events',
    const StandardMethodCodec().encodeSuccessEnvelope(event),
    (_) {},
  );

  for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
    test(
      '${platform.name} listens, and reduceMotion follows each event',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        final a = MethodChannelXAccessibility();
        await pumpEventQueue();
        expect(listenCalls, ['listen']);
        expect(a.reduceMotion.value, isFalse);

        await sendEvent({'type': 'reduceMotion', 'reduced': true});
        expect(a.reduceMotion.value, isTrue);

        await sendEvent({'type': 'reduceMotion', 'reduced': false});
        expect(a.reduceMotion.value, isFalse);
      },
    );
  }

  test(
    'iOS, whose Flutter features carry Reduce Motion, does not listen',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final a = MethodChannelXAccessibility();
      await pumpEventQueue();
      expect(listenCalls, isEmpty);
      expect(a.reduceMotion.value, isFalse);
    },
  );
}
