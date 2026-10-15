import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/notifications.dart';

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
  const methods = MethodChannel('ux/notifications');
  const events = MethodChannel('ux/notifications/events');

  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      return call.method == 'requestPermission' ? true : null;
    });
    messenger.setMockMethodCallHandler(events, (_) async => null);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(events, null);
    debugDefaultTargetPlatformOverride = null;
  });

  Future<void> sendEvent(Object? event) => messenger.handlePlatformMessage(
    'ux/notifications/events',
    const StandardMethodCodec().encodeSuccessEnvelope(event),
    (_) {},
  );

  // Regression: iOS has no native handler, so activating the broadcast
  // stream throws MissingPluginException straight to FlutterError.onError.
  test('iOS does not activate the events channel', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final eventCalls = <String>[];
    messenger.setMockMethodCallHandler(events, (call) async {
      eventCalls.add(call.method);
      return null;
    });
    MethodChannelXNotifications();
    await pumpEventQueue();
    expect(eventCalls, isEmpty);
  });

  test('Android activates the events channel', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final eventCalls = <String>[];
    messenger.setMockMethodCallHandler(events, (call) async {
      eventCalls.add(call.method);
      return null;
    });
    MethodChannelXNotifications();
    await pumpEventQueue();
    expect(eventCalls, contains('listen'));
  });

  test('show forwards the exact argument map', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final n = MethodChannelXNotifications();
    await n.show(
      XNotification(
        id: 'd1:7',
        title: 'Alice',
        body: 'hi',
        threadId: 'd1',
        data: const {'dialogId': 'd1', 'messageId': '7'},
      ),
    );
    final show = calls.firstWhere((c) => c.method == 'show');
    expect(show.arguments, {
      'id': 'd1:7',
      'title': 'Alice',
      'body': 'hi',
      'threadId': 'd1',
      'data': {'dialogId': 'd1', 'messageId': '7'},
    });
  });

  test('requestPermission invokes the method and updates authorized', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final n = MethodChannelXNotifications();
    expect(await n.requestPermission(), isTrue);
    expect(calls.any((c) => c.method == 'requestPermission'), isTrue);
    expect(n.authorized.value, isTrue);
  });

  test('cancelByThread and cancelAll invoke their methods', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final n = MethodChannelXNotifications();
    await n.cancelByThread('d1');
    await n.cancelAll();
    expect(
      calls.any(
        (c) =>
            c.method == 'cancelByThread' &&
            (c.arguments as Map)['threadId'] == 'd1',
      ),
      isTrue,
    );
    expect(calls.any((c) => c.method == 'cancelAll'), isTrue);
  });

  test('Windows activates the events channel, whose authorization and tap '
      'events reach the Dart side', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final eventCalls = <String>[];
    messenger.setMockMethodCallHandler(events, (call) async {
      eventCalls.add(call.method);
      return null;
    });
    final n = MethodChannelXNotifications();
    await pumpEventQueue();
    expect(eventCalls, contains('listen'));
    final taps = <Map<String, String>>[];
    n.onTap.listen(taps.add);

    await sendEvent({'type': 'authorization', 'granted': true});
    await pumpEventQueue();
    expect(n.authorized.value, isTrue);

    await sendEvent({
      'type': 'tap',
      'data': {'dialogId': 'd1', 'messageId': '7'},
    });
    await pumpEventQueue();
    expect(taps, [
      {'dialogId': 'd1', 'messageId': '7'},
    ]);
  });
}
