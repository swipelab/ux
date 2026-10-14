import 'dart:async';
import 'dart:io' as io;
import 'dart:ui' show Size;

import 'package:flutter/services.dart'
    show EventChannel, MethodChannel, PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/log.dart';
import 'package:ux/testing.dart';
import 'package:ux/video.dart';

/// Holds create, initialize and disposeInstance while their completer is
/// pending, and records every events subscription.
class _HeldBackend extends FakeXVideoPlayerBackend {
  Completer<void>? createHeld;
  Completer<void>? initializeHeld;
  Completer<void>? disposeHeld;
  final List<int> eventsCalls = [];

  @override
  Future<XVideoPlayerCreateResult> create({required String uri}) async {
    final result = await super.create(uri: uri);
    await createHeld?.future;
    return result;
  }

  @override
  Future<XVideoPlayerMetadata> initialize(int handle) async {
    final metadata = await super.initialize(handle);
    await initializeHeld?.future;
    return metadata;
  }

  @override
  Future<void> disposeInstance(int handle) async {
    await disposeHeld?.future;
    await super.disposeInstance(handle);
  }

  @override
  Stream<XVideoPlayerEvent> events(int handle) {
    eventsCalls.add(handle);
    return super.events(handle);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeXVideoPlayerBackend fake;

  setUp(() {
    fake = FakeXVideoPlayerBackend(
      size: const Size(720, 1280),
      duration: const Duration(seconds: 30),
    );
    XVideoPlayerBackend.instance = fake;
  });

  tearDown(() {
    XVideoPlayerBackend.instance = MethodChannelXVideoPlayerBackend();
  });

  test('initialize creates the native instance, subscribes to events, '
      'and populates size + duration', () async {
    final ctrl = XVideoPlayerController.file(io.File('/tmp/fake.mp4'));
    addTearDown(ctrl.dispose);

    expect(ctrl.value.isInitialized, isFalse);
    expect(ctrl.value.size, Size.zero);

    await ctrl.initialize();

    expect(fake.createCalls.single, 'file:///tmp/fake.mp4');
    expect(fake.initializeCalls.single, 1);
    expect(ctrl.handle, 1);
    expect(ctrl.textureId, 101);
    expect(ctrl.value.isInitialized, isTrue);
    expect(ctrl.value.size, const Size(720, 1280));
    expect(ctrl.value.duration, const Duration(seconds: 30));
    expect(ctrl.value.aspectRatio, 720.0 / 1280.0);
  });

  test('initialize logs the handle, size, duration and quarter turns it '
      'reports', () async {
    final (minLevel, previous) = (Log.minLevel, Log.sink);
    final sink = MemorySink();
    Log.configure(minLevel: LogLevel.trace, sink: sink, captureCrashes: () {});
    addTearDown(() =>
        Log.configure(minLevel: minLevel, sink: previous, captureCrashes: () {}));
    fake.rotationQuarterTurns = 3;
    final ctrl = XVideoPlayerController.file(io.File('/tmp/fake.mp4'));
    addTearDown(ctrl.dispose);

    await ctrl.initialize();

    final record = sink.snapshot().singleWhere((r) => r.tag == 'video');
    expect(record.level, LogLevel.info);
    expect(record.message, 'initialized');
    expect(record.fields, {
      'handle': 1,
      'width': 720.0,
      'height': 1280.0,
      'durationMs': 30000,
      'rotationQuarterTurns': 3,
    });
  });

  test('play / pause flip isPlaying and forward to the backend', () async {
    final ctrl = XVideoPlayerController.file(io.File('/tmp/fake.mp4'));
    addTearDown(ctrl.dispose);
    await ctrl.initialize();

    await ctrl.play();
    expect(fake.playCalls.single, 1);
    expect(ctrl.value.isPlaying, isTrue);

    await ctrl.pause();
    expect(fake.pauseCalls.single, 1);
    expect(ctrl.value.isPlaying, isFalse);
  });

  test('seekTo clamps to [0, duration] and forwards the clamped value',
      () async {
    final ctrl = XVideoPlayerController.file(io.File('/tmp/fake.mp4'));
    addTearDown(ctrl.dispose);
    await ctrl.initialize();

    await ctrl.seekTo(const Duration(seconds: -5));
    expect(fake.seekToCalls.last.position, Duration.zero);
    expect(ctrl.value.position, Duration.zero);

    await ctrl.seekTo(const Duration(minutes: 99));
    expect(fake.seekToCalls.last.position, const Duration(seconds: 30));
    expect(ctrl.value.position, const Duration(seconds: 30));

    await ctrl.seekTo(const Duration(seconds: 10));
    expect(fake.seekToCalls.last.position, const Duration(seconds: 10));
  });

  test('setLooping / setVolume / setPlaybackSpeed clamp and forward',
      () async {
    final ctrl = XVideoPlayerController.file(io.File('/tmp/fake.mp4'));
    addTearDown(ctrl.dispose);
    await ctrl.initialize();

    await ctrl.setLooping(true);
    expect(fake.setLoopingCalls.single, (handle: 1, loop: true));
    expect(ctrl.value.isLooping, isTrue);

    await ctrl.setVolume(1.5);
    expect(fake.setVolumeCalls.single.volume, 1.0);
    expect(ctrl.value.volume, 1.0);

    await ctrl.setVolume(-1.0);
    expect(fake.setVolumeCalls.last.volume, 0.0);
    expect(ctrl.value.volume, 0.0);

    await ctrl.setPlaybackSpeed(0.0);
    expect(fake.setPlaybackSpeedCalls.last.rate, 0.25);
    expect(ctrl.value.playbackSpeed, 0.25);

    await ctrl.setPlaybackSpeed(10.0);
    expect(fake.setPlaybackSpeedCalls.last.rate, 4.0);
    expect(ctrl.value.playbackSpeed, 4.0);
  });

  test('stateChanged events flow into value (position, buffered, isPlaying)',
      () async {
    final ctrl = XVideoPlayerController.file(io.File('/tmp/fake.mp4'));
    addTearDown(ctrl.dispose);
    await ctrl.initialize();

    fake.emitState(
      1,
      isPlaying: true,
      position: const Duration(seconds: 5),
      buffered: [
        XDurationRange(Duration.zero, const Duration(seconds: 20)),
      ],
    );
    await Future<void>.delayed(Duration.zero);

    expect(ctrl.value.isPlaying, isTrue);
    expect(ctrl.value.position, const Duration(seconds: 5));
    expect(ctrl.value.buffered, hasLength(1));
    expect(ctrl.value.buffered.single.end, const Duration(seconds: 20));
  });

  test('sizeChanged events update value.size', () async {
    final ctrl = XVideoPlayerController.file(io.File('/tmp/fake.mp4'));
    addTearDown(ctrl.dispose);
    await ctrl.initialize();

    fake.emitSizeChanged(1, const Size(1280, 720));
    await Future<void>.delayed(Duration.zero);

    expect(ctrl.value.size, const Size(1280, 720));
    expect(ctrl.value.aspectRatio, 1280.0 / 720.0);
  });

  test('error events set hasError and stop further state mutations', () async {
    final ctrl = XVideoPlayerController.file(io.File('/tmp/fake.mp4'));
    addTearDown(ctrl.dispose);
    await ctrl.initialize();

    fake.emitError(1, 'decode_failed', 'codec init failure');
    await Future<void>.delayed(Duration.zero);

    expect(ctrl.value.hasError, isTrue);
    expect(ctrl.value.errorDescription, 'codec init failure');
  });

  test('completed event with looping=false flips isPlaying off; '
      'with looping=true it stays on (native loop is silent)', () async {
    final ctrl = XVideoPlayerController.file(io.File('/tmp/fake.mp4'));
    addTearDown(ctrl.dispose);
    await ctrl.initialize();

    await ctrl.play();
    expect(ctrl.value.isPlaying, isTrue);

    fake.emitCompleted(1);
    await Future<void>.delayed(Duration.zero);
    expect(ctrl.value.isPlaying, isFalse);

    await ctrl.play();
    await ctrl.setLooping(true);
    fake.emitCompleted(1);
    await Future<void>.delayed(Duration.zero);
    // Looping mode: completion is a no-op on the value; native handles
    // the rewind. value.isPlaying remains true.
    expect(ctrl.value.isPlaying, isTrue);
  });

  test('dispose is idempotent and prevents further operations', () async {
    final ctrl = XVideoPlayerController.file(io.File('/tmp/fake.mp4'));
    await ctrl.initialize();
    await ctrl.dispose();
    await ctrl.dispose(); // second dispose is a no-op
    expect(fake.disposeCalls, [1]);
    expect(
      () => ctrl.play(),
      throwsA(isA<XVideoPlayerException>()),
    );
  });

  test('initialize failure tears down the native instance so a retry '
      'is not blocked by a leaked claim', () async {
    fake.initializeError = const XVideoPlayerException('decode_failed');
    final ctrl = XVideoPlayerController.file(io.File('/tmp/fake.mp4'));
    addTearDown(ctrl.dispose);

    await expectLater(
      ctrl.initialize(),
      throwsA(isA<XVideoPlayerException>()),
    );

    // The controller has a handle from `create` even though `initialize`
    // threw; dispose must have been called to release it.
    expect(fake.disposeCalls.single, 1);
  });

  test('a native dispose failure on the channel backend leaves dispose '
      'completing its teardown', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('ux/video');
    final disposeCalls = <Object?>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'create':
          return {'handle': 1};
        case 'initialize':
          return {
            'size': {'width': 720, 'height': 1280},
            'durationMs': 1000,
          };
        case 'dispose':
          disposeCalls.add(call.arguments);
          throw PlatformException(code: 'native_error');
      }
      return null;
    });
    messenger.setMockStreamHandler(
      const EventChannel('ux/video/events'),
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockStreamHandler(
        const EventChannel('ux/video/events'),
        null,
      );
    });
    XVideoPlayerBackend.instance = MethodChannelXVideoPlayerBackend();
    final ctrl = XVideoPlayerController.file(io.File('/tmp/fake.mp4'));
    await ctrl.initialize();

    await ctrl.dispose();
    await ctrl.dispose();

    expect(disposeCalls, [
      {'handle': 1},
    ]);
    expect(() => ctrl.addListener(() {}), throwsFlutterError);
  });

  group('dispose while a native call is pending', () {
    late _HeldBackend held;
    late XVideoPlayerController ctrl;
    var notified = 0;

    setUp(() {
      held = _HeldBackend();
      XVideoPlayerBackend.instance = held;
      ctrl = XVideoPlayerController.file(io.File('/tmp/fake.mp4'));
      notified = 0;
      ctrl.addListener(() => notified++);
    });

    test('a handle created after dispose is disposed, never subscribed, '
        'and initialize fails as disposed', () async {
      held.createHeld = Completer<void>();
      final init = ctrl.initialize();
      await ctrl.dispose();

      held.createHeld!.complete();
      await expectLater(
        init,
        throwsA(
          isA<XVideoPlayerException>().having(
            (e) => e.code,
            'code',
            'disposed',
          ),
        ),
      );

      expect(held.disposeCalls, [1]);
      expect(held.eventsCalls, isEmpty);
      expect(held.initializeCalls, isEmpty);
      expect(notified, 0);
    });

    test('metadata arriving after dispose leaves the controller '
        'uninitialized and initialize fails as disposed', () async {
      held.initializeHeld = Completer<void>();
      final init = ctrl.initialize();
      await pumpEventQueue();
      expect(held.initializeCalls, [1]);
      await ctrl.dispose();

      held.initializeHeld!.complete();
      await expectLater(
        init,
        throwsA(
          isA<XVideoPlayerException>().having(
            (e) => e.code,
            'code',
            'disposed',
          ),
        ),
      );

      expect(held.disposeCalls, [1]);
      expect(ctrl.value.isInitialized, isFalse);
      expect(notified, 0);
    });

    test('an event arriving while the native player is torn down '
        'notifies nobody', () async {
      await ctrl.initialize();
      notified = 0;
      held.disposeHeld = Completer<void>();
      final disposed = ctrl.dispose();

      held.emitState(1, isPlaying: true);
      await pumpEventQueue();
      held.disposeHeld!.complete();
      await disposed;

      expect(ctrl.value.isPlaying, isFalse);
      expect(notified, 0);
    });
  });
}
