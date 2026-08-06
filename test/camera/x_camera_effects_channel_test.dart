import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/ux.dart';

const _methodChannelName = 'ux/camera_effects';
const _eventChannelName = 'ux/camera_effects/events';
const _methods = MethodChannel(_methodChannelName);
const _events = MethodChannel(_eventChannelName);

Map<String, Object?> _status(
  String phase,
  String effect,
  int generation, {
  String? code,
}) =>
    {
      'phase': phase,
      'effect': effect,
      'generation': generation,
      if (code != null) 'code': code,
    };

Map<Object?, Object?> _argumentsOf(MethodCall call) =>
    (call.arguments as Map).cast<Object?, Object?>();

int _generationOf(MethodCall call) => _argumentsOf(call)['generation']! as int;

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;

  late MethodChannelXCameraEffectsBackend backend;
  late List<MethodCall> calls;
  Future<Object?> Function(MethodCall call)? handler;
  Future<void> Function()? onListen;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    backend = MethodChannelXCameraEffectsBackend();
    calls = [];
    handler = (_) async => null;
    onListen = null;
    messenger.setMockMethodCallHandler(_methods, (call) async {
      calls.add(call);
      return handler?.call(call);
    });
    messenger.setMockMethodCallHandler(_events, (call) async {
      if (call.method == 'listen') await onListen?.call();
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_methods, null);
    messenger.setMockMethodCallHandler(_events, null);
    debugDefaultTargetPlatformOverride = null;
  });

  Future<void> sendEvent(Object? event) => messenger.handlePlatformMessage(
        _eventChannelName,
        const StandardMethodCodec().encodeSuccessEnvelope(event),
        (_) {},
      );

  Future<void> sendStreamError() => messenger.handlePlatformMessage(
        _eventChannelName,
        const StandardMethodCodec().encodeErrorEnvelope(code: 'stream_failed'),
        (_) {},
      );

  Future<int> effectApplied([XCameraEffect effect = XCameraEffect.blur]) async {
    await backend.setEffect('track:1', effect);
    await pumpEventQueue();
    return _generationOf(calls.last);
  }

  group('command wire', () {
    test('setEffect carries the track, the effect name and a generation',
        () async {
      await backend.setEffect('track:1', XCameraEffect.blur);

      final call = calls.single;
      expect(call.method, 'setEffect');
      final arguments = _argumentsOf(call);
      expect(arguments.keys.toSet(), {'trackId', 'effect', 'generation'});
      expect(arguments['trackId'], 'track:1');
      expect(arguments['effect'], 'blur');
      expect(arguments['generation'], isA<int>());
    });

    test('dim rides the wire under its own name', () async {
      await backend.setEffect('track:1', XCameraEffect.dim);

      expect(_argumentsOf(calls.single)['effect'], 'dim');
    });

    test('clear carries exactly a generation', () async {
      await backend.clear();

      expect(calls.single.method, 'clear');
      expect(_argumentsOf(calls.single).keys.toSet(), {'generation'});
    });

    test('a none effect invokes clear', () async {
      await backend.setEffect('track:1', XCameraEffect.none);

      expect(calls.single.method, 'clear');
      expect(_argumentsOf(calls.single).keys.toSet(), {'generation'});
    });

    test('available carries its name and no arguments', () async {
      handler = (_) async => true;

      expect(await backend.available(), isTrue);
      expect(calls.single.method, 'available');
      expect(calls.single.arguments, isNull);
    });
  });

  group('exception mapping', () {
    for (final code in const [
      'unsupported',
      'integration_unavailable',
      'track_not_found',
      'track_not_processable',
      'initialization_failed',
      'something_native_invented',
    ]) {
      test('$code passes through code-for-code', () async {
        handler =
            (_) async => throw PlatformException(code: code, message: 'detail');

        await expectLater(
          backend.setEffect('track:1', XCameraEffect.blur),
          throwsA(
            isA<XCameraEffectsException>()
                .having((e) => e.code, 'code', code)
                .having((e) => e.message, 'message', 'detail'),
          ),
        );
      });
    }

    test('a missing native handler is integration_unavailable', () async {
      messenger.setMockMethodCallHandler(_methods, null);

      for (final command in [
        backend.available(),
        backend.setEffect('track:1', XCameraEffect.blur),
        backend.clear(),
      ]) {
        await expectLater(
          command,
          throwsA(
            isA<XCameraEffectsException>()
                .having((e) => e.code, 'code', 'integration_unavailable'),
          ),
        );
      }
    });

    test('an available reply that is not a bool is invalid_response', () async {
      handler = (_) async => 'yes';

      await expectLater(
        backend.available(),
        throwsA(
          isA<XCameraEffectsException>()
              .having((e) => e.code, 'code', 'invalid_response')
              .having((e) => e.message, 'message', startsWith('result:')),
        ),
      );
    });
  });

  group('serialization', () {
    test('overlapping commands reach the channel in order', () async {
      final firstReached = Completer<void>();
      final releaseFirst = Completer<void>();
      handler = (call) async {
        if (!firstReached.isCompleted) {
          firstReached.complete();
          await releaseFirst.future;
        }
        return null;
      };

      final first = backend.setEffect('track:1', XCameraEffect.blur);
      await firstReached.future;
      final second = backend.setEffect('track:1', XCameraEffect.dim);
      final third = backend.clear();
      await pumpEventQueue();
      expect(calls, hasLength(1));

      releaseFirst.complete();
      await Future.wait([first, second, third]);

      expect(calls.map((c) => c.method), ['setEffect', 'setEffect', 'clear']);
      expect(calls.map(_generationOf), [1, 2, 3]);
    });

    test('a queued command runs after the one before it fails', () async {
      handler = (_) async {
        if (calls.length == 1) throw PlatformException(code: 'track_not_found');
        return null;
      };

      final first = backend.setEffect('track:1', XCameraEffect.blur);
      final second = backend.clear();

      await expectLater(first, throwsA(isA<XCameraEffectsException>()));
      await second;
      expect(calls.map((c) => c.method), ['setEffect', 'clear']);
    });

    test('a repeated identical setEffect carries a new generation', () async {
      await backend.setEffect('track:1', XCameraEffect.blur);
      await backend.setEffect('track:1', XCameraEffect.blur);

      expect(calls.map((c) => c.method), ['setEffect', 'setEffect']);
      expect(calls.map(_generationOf), [1, 2]);
    });
  });

  group('status', () {
    test('the status the stream is activated with reaches the listenable',
        () async {
      onListen = () => sendEvent(
            _status('applying', 'blur', _generationOf(calls.last)),
          );

      await backend.setEffect('track:1', XCameraEffect.blur);
      await pumpEventQueue();

      expect(calls.map((c) => c.method), ['setEffect']);
      expect(
        backend.status.value,
        const XCameraEffectStatus(
          phase: XCameraEffectPhase.applying,
          effect: XCameraEffect.blur,
        ),
      );
    });

    test('applying and active arrive in order', () async {
      final generation = await effectApplied();
      final seen = <XCameraEffectPhase>[];
      backend.status.addListener(() => seen.add(backend.status.value.phase));

      await sendEvent(_status('applying', 'blur', generation));
      await pumpEventQueue();
      await sendEvent(_status('active', 'blur', generation));
      await pumpEventQueue();

      expect(seen, [XCameraEffectPhase.applying, XCameraEffectPhase.active]);
    });

    test('a completed setEffect does not itself report active', () async {
      await effectApplied();

      expect(backend.status.value, const XCameraEffectStatus.idle());
    });

    test('a processing fault arrives as a failed status', () async {
      final generation = await effectApplied();

      await sendEvent(
        _status('failed', 'blur', generation, code: 'processing_failed'),
      );
      await pumpEventQueue();

      expect(
        backend.status.value,
        const XCameraEffectStatus(
          phase: XCameraEffectPhase.failed,
          effect: XCameraEffect.blur,
          code: 'processing_failed',
        ),
      );
    });

    test('a completed clear settles the status to idle', () async {
      final generation = await effectApplied();
      await sendEvent(_status('active', 'blur', generation));
      await pumpEventQueue();

      await backend.clear();

      expect(backend.status.value, const XCameraEffectStatus.idle());
    });

    test('every phase and effect name decodes', () async {
      final generation = await effectApplied();
      const expected = [
        XCameraEffectStatus(
          phase: XCameraEffectPhase.applying,
          effect: XCameraEffect.blur,
        ),
        XCameraEffectStatus(
          phase: XCameraEffectPhase.active,
          effect: XCameraEffect.blur,
        ),
        XCameraEffectStatus(
          phase: XCameraEffectPhase.applying,
          effect: XCameraEffect.dim,
        ),
        XCameraEffectStatus(
          phase: XCameraEffectPhase.active,
          effect: XCameraEffect.dim,
        ),
        XCameraEffectStatus(
          phase: XCameraEffectPhase.failed,
          effect: XCameraEffect.dim,
          code: 'processing_failed',
        ),
        XCameraEffectStatus.idle(),
      ];

      for (final status in expected) {
        await sendEvent(
          _status(
            status.phase.name,
            status.effect.name,
            generation,
            code: status.code,
          ),
        );
        await pumpEventQueue();

        expect(backend.status.value, status);
      }
    });
  });

  group('generations', () {
    test('status from before a clear never reaches the listenable', () async {
      final effected = await effectApplied();
      await sendEvent(_status('active', 'blur', effected));
      await pumpEventQueue();
      await backend.clear();

      await sendEvent(_status('active', 'blur', effected));
      await pumpEventQueue();

      expect(backend.status.value, const XCameraEffectStatus.idle());
    });

    test('status older than a newer command is dropped', () async {
      final effected = await effectApplied();
      await sendEvent(_status('active', 'blur', effected));
      await pumpEventQueue();
      await backend.setEffect('track:2', XCameraEffect.dim);

      await sendEvent(
        _status('failed', 'blur', effected, code: 'processing_failed'),
      );
      await pumpEventQueue();

      expect(
        backend.status.value,
        const XCameraEffectStatus(
          phase: XCameraEffectPhase.active,
          effect: XCameraEffect.blur,
        ),
      );
    });

    test('a fault from the live effect arrives after a command throws',
        () async {
      final effected = await effectApplied();
      await sendEvent(_status('active', 'blur', effected));
      await pumpEventQueue();
      handler = (_) async => throw PlatformException(code: 'track_not_found');

      await expectLater(
        backend.setEffect('track:2', XCameraEffect.dim),
        throwsA(isA<XCameraEffectsException>()),
      );
      expect(
        backend.status.value,
        const XCameraEffectStatus(
          phase: XCameraEffectPhase.active,
          effect: XCameraEffect.blur,
        ),
      );

      await sendEvent(
        _status('failed', 'blur', effected, code: 'processing_failed'),
      );
      await pumpEventQueue();

      expect(
        backend.status.value,
        const XCameraEffectStatus(
          phase: XCameraEffectPhase.failed,
          effect: XCameraEffect.blur,
          code: 'processing_failed',
        ),
      );
    });
  });

  group('malformed events', () {
    const active = XCameraEffectStatus(
      phase: XCameraEffectPhase.active,
      effect: XCameraEffect.blur,
    );

    Future<int> drivenToActive() async {
      final generation = await effectApplied();
      await sendEvent(_status('active', 'blur', generation));
      await pumpEventQueue();
      expect(backend.status.value, active);
      return generation;
    }

    test('a payload that is not a map is dropped', () async {
      await drivenToActive();

      await sendEvent('active');
      await pumpEventQueue();

      expect(backend.status.value, active);
    });

    test('an unknown phase is dropped', () async {
      final generation = await drivenToActive();

      await sendEvent(_status('settling', 'blur', generation));
      await pumpEventQueue();

      expect(backend.status.value, active);
    });

    test('an unknown effect is dropped', () async {
      final generation = await drivenToActive();

      await sendEvent(_status('applying', 'sepia', generation));
      await pumpEventQueue();

      expect(backend.status.value, active);
    });

    test('a missing generation is dropped', () async {
      await drivenToActive();

      await sendEvent({'phase': 'applying', 'effect': 'dim'});
      await pumpEventQueue();

      expect(backend.status.value, active);
    });

    test('a generation of the wrong type is dropped', () async {
      await drivenToActive();

      await sendEvent({
        'phase': 'applying',
        'effect': 'dim',
        'generation': '3',
      });
      await pumpEventQueue();

      expect(backend.status.value, active);
    });

    test('a code outside a failed phase is dropped', () async {
      final generation = await drivenToActive();

      await sendEvent(
        _status('applying', 'dim', generation, code: 'processing_failed'),
      );
      await pumpEventQueue();

      expect(backend.status.value, active);
    });

    test('an idle phase carrying an effect is dropped', () async {
      final generation = await drivenToActive();

      await sendEvent(_status('idle', 'dim', generation));
      await pumpEventQueue();

      expect(backend.status.value, active);
    });

    test('a stream error is dropped and the next status still arrives',
        () async {
      final generation = await drivenToActive();

      await sendStreamError();
      await pumpEventQueue();
      expect(backend.status.value, active);

      await sendEvent(
        _status('failed', 'blur', generation, code: 'processing_failed'),
      );
      await pumpEventQueue();

      expect(backend.status.value.phase, XCameraEffectPhase.failed);
    });
  });
}
