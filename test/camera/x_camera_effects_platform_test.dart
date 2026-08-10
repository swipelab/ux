import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/src/camera/x_camera_effects.dart';
import 'package:ux/src/camera/x_camera_effects_channel.dart';

const _methods = MethodChannel('ux/camera_effects');
const _events = MethodChannel('ux/camera_effects/events');

Matcher _failsWith(String code) => throwsA(
      isA<XCameraEffectsException>().having((e) => e.code, 'code', code),
    );

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;

  group('platform family', () {
    late List<MethodCall> calls;

    setUp(() {
      calls = [];
      for (final channel in const [_methods, _events]) {
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
      }
    });

    tearDown(() {
      for (final channel in const [_methods, _events]) {
        messenger.setMockMethodCallHandler(channel, null);
      }
      debugDefaultTargetPlatformOverride = null;
    });

    for (final platform in const [
      TargetPlatform.macOS,
      TargetPlatform.iOS,
      TargetPlatform.android,
    ]) {
      test('$platform is supported', () {
        debugDefaultTargetPlatformOverride = platform;

        expect(MethodChannelXCameraEffectsBackend().supported, isTrue);
      });
    }

    for (final platform in const [
      TargetPlatform.linux,
      TargetPlatform.windows,
      TargetPlatform.fuchsia,
    ]) {
      group('$platform', () {
        late MethodChannelXCameraEffectsBackend backend;

        setUp(() {
          debugDefaultTargetPlatformOverride = platform;
          backend = MethodChannelXCameraEffectsBackend();
        });

        test('is not supported', () {
          expect(backend.supported, isFalse);
        });

        test('every method throws unsupported and touches no channel',
            () async {
          await expectLater(backend.available(), _failsWith('unsupported'));
          await expectLater(
            backend.setEffect('track:1', XCameraEffect.blur),
            _failsWith('unsupported'),
          );
          await expectLater(
            backend.setEffect('track:1', XCameraEffect.none),
            _failsWith('unsupported'),
          );
          await expectLater(backend.clear(), _failsWith('unsupported'));
          expect(calls, isEmpty);
        });

        test('the status stays idle', () async {
          await expectLater(
            backend.setEffect('track:1', XCameraEffect.blur),
            _failsWith('unsupported'),
          );

          expect(backend.status.value, const XCameraEffectStatus.idle());
        });
      });
    }
  });

  group('macOS with no native handler', () {
    late MethodChannelXCameraEffectsBackend backend;
    late List<MethodCall> eventCalls;
    late List<FlutterErrorDetails> errors;

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      eventCalls = [];
      messenger.setMockMethodCallHandler(_events, (call) async {
        eventCalls.add(call);
        return null;
      });
      errors = [];
      final reportError = FlutterError.onError;
      FlutterError.onError = errors.add;
      addTearDown(() => FlutterError.onError = reportError);
      backend = MethodChannelXCameraEffectsBackend();
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(_events, null);
      debugDefaultTargetPlatformOverride = null;
    });

    test('every command fails integration_unavailable', () async {
      await expectLater(
        backend.available(),
        _failsWith('integration_unavailable'),
      );
      await expectLater(
        backend.setEffect('track:1', XCameraEffect.blur),
        _failsWith('integration_unavailable'),
      );
      await expectLater(backend.clear(), _failsWith('integration_unavailable'));
    });

    test('reading the status subscribes to nothing and reports no error',
        () async {
      expect(backend.status.value, const XCameraEffectStatus.idle());
      await expectLater(
        backend.available(),
        _failsWith('integration_unavailable'),
      );
      await pumpEventQueue();

      expect(eventCalls, isEmpty);
      expect(errors, isEmpty);
    });
  });
}
