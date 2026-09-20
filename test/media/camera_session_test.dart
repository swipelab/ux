import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/camera.dart';
import 'package:ux/media.dart';

import 'camera_test_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CameraTestBackend backend;
  late CameraSession session;

  setUp(() {
    backend = CameraTestBackend();
    XCameraBackend.instance = backend;
    session = CameraSession();
  });

  tearDown(() async {
    await session.dispose();
    expect(backend.liveHandles, isEmpty);
    expect(backend.listeners, 0);
    XCameraBackend.instance = MethodChannelXCameraBackend();
  });

  test('concurrent initialization shares one controller and texture', () async {
    final controllers = await Future.wait([
      session.initialize(),
      session.initialize(),
    ]);
    expect(controllers.first, same(controllers.last));
    expect(session.value, same(controllers.first));
    expect(session.value!.textureId, 100);
    expect(backend.createCalls, hasLength(1));
    expect(
      backend.lockCaptureOrientationCalls.single.orientation,
      DeviceOrientation.portraitUp,
    );
  });

  test('closing during discovery allocates nothing', () async {
    backend.discoveryGate = Completer();
    final opening = session.initialize();
    await Future<void>.delayed(Duration.zero);
    final closing = session.dispose();
    backend.discoveryGate!.complete();
    expect(await opening, isNull);
    await closing;
    expect(backend.createCalls, isEmpty);
  });

  test(
    'closing before create returns releases the late native allocation',
    () async {
      backend.createGate = Completer();
      final opening = session.initialize();
      await Future<void>.delayed(Duration.zero);
      expect(backend.liveHandles, {1});
      final closing = session.dispose();
      backend.createGate!.complete();
      expect(await opening, isNull);
      await closing;
      expect(session.value, isNull);
      expect(backend.disposeCalls, [1]);
    },
  );

  test(
    'closing during native initialization cancels its event listener',
    () async {
      backend.initializeGate = Completer();
      final opening = session.initialize();
      await Future<void>.delayed(Duration.zero);
      expect(backend.listeners, 1);
      final closing = session.dispose();
      expect(await session.initialize(), isNull);
      backend.initializeGate!.complete();
      expect(await opening, isNull);
      await closing;
      expect(backend.disposeCalls, [1]);
      expect(backend.lockCaptureOrientationCalls, isEmpty);
    },
  );

  test('orientation-lock failure releases the initialized controller and permits retry', () async {
    backend.lockError = const XCameraException('lock_failed');
    await expectLater(session.initialize(), throwsA(isA<XCameraException>()));
    expect(session.value, isNull);
    expect(backend.liveHandles, isEmpty);
    expect(backend.listeners, 0);
    backend.lockError = null;
    expect(await session.initialize(), isNotNull);
    expect(backend.createCalls, hasLength(2));
  });

  test('audio replacement waits for a lens change and publishes the new controller', () async {
    final first = await session.initialize();
    final observed = <XCameraController?>[];
    session.addListener(() => observed.add(session.value));
    backend.descriptionGate = Completer();
    final flipping = session.flipCamera();
    final replacing = session.ensureAudio();
    await Future<void>.delayed(Duration.zero);
    expect(backend.createCalls, hasLength(1));
    backend.descriptionGate!.complete();
    await flipping;
    final replacement = await replacing;
    expect(replacement, isNot(same(first)));
    expect(replacement!.description, backCamera);
    expect(replacement.enableAudio, isTrue);
    expect(session.value, same(replacement));
    expect(observed, [first, null, replacement]);
    expect(backend.disposeCalls, [1]);
    expect(backend.liveHandles, {2});
    expect(backend.listeners, 1);
  });

  test(
    'failed audio initialization releases its claim before silent fallback',
    () async {
      await session.initialize();
      backend.failAudioInitialization = true;
      final replacement = await session.ensureAudio();
      expect(replacement!.enableAudio, isFalse);
      expect(backend.createCalls.map((call) => call.enableAudio), [
        false,
        true,
        false,
      ]);
      expect(backend.disposeCalls, [1, 2]);
      expect(backend.liveHandles, {3});
      expect(backend.listeners, 1);
    },
  );

  test(
    'closing a pending audio replacement releases it without silent reopening',
    () async {
      await session.initialize();
      backend.initializeGate = Completer();
      backend.failAudioInitialization = true;
      final replacement = session.ensureAudio();
      await Future<void>.delayed(Duration.zero);
      expect(backend.liveHandles, {2});
      final closing = session.dispose();
      backend.initializeGate!.complete();
      expect(await replacement, isNull);
      await closing;
      expect(backend.createCalls, hasLength(2));
      expect(backend.disposeCalls, [1, 2]);
    },
  );

  test('disposal waits for controller use and rejects queued work', () async {
    await session.initialize();
    final captureGate = Completer<void>();
    final capture = session.useController((controller) async {
      await captureGate.future;
      return controller.takePicture(
        captureOrientation: DeviceOrientation.portraitUp,
      );
    });
    await Future<void>.delayed(Duration.zero);
    final closing = session.dispose();
    final queued = session.ensureAudio();
    expect(session.value, isNull);
    expect(backend.disposeCalls, isEmpty);
    captureGate.complete();
    expect((await capture)!.path, backend.picturePath);
    await closing;
    expect(await queued, isNull);
    expect(backend.disposeCalls, [1]);
  });

  test(
    'empty discovery is an absent camera, not an allocation failure',
    () async {
      backend.cameras = [];
      expect(await session.initialize(), isNull);
      expect(session.cameras, isEmpty);
      expect(backend.createCalls, isEmpty);
    },
  );
}
