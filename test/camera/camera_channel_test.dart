import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/camera.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MethodChannelXCameraBackend — arg/return parsing', () {
    const channel = MethodChannel('ux/camera');

    late MethodChannelXCameraBackend backend;
    late List<MethodCall> calls;

    setUp(() {
      backend = MethodChannelXCameraBackend();
      calls = [];
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    void handle(Object? Function(MethodCall) reply) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return reply(call);
          });
    }

    test('availableCameras decodes the platform list', () async {
      handle(
        (_) => [
          {'id': 'a', 'lens': 'front', 'sensorOrientation': 270},
          {'id': 'b', 'lens': 'back', 'sensorOrientation': 90},
        ],
      );

      final result = await backend.availableCameras();

      expect(calls.single.method, 'availableCameras');
      expect(result, [
        const XCameraDescription(
          id: 'a',
          lens: XCameraLens.front,
          sensorOrientation: 270,
        ),
        const XCameraDescription(
          id: 'b',
          lens: XCameraLens.back,
          sensorOrientation: 90,
        ),
      ]);
    });

    test(
      'create sends cameraId/enableAudio/preset and decodes the tuple',
      () async {
        handle(
          (_) => {
            'handle': 42,
            'textureId': 7,
            'previewSize': {'width': 1920, 'height': 1080},
          },
        );

        final result = await backend.create(
          cameraId: 'cam-1',
          enableAudio: true,
          preset: XResolutionPreset.high,
        );

        expect(calls.single.method, 'create');
        expect(calls.single.arguments, {
          'cameraId': 'cam-1',
          'enableAudio': true,
          'preset': 'high',
        });
        expect(result.handle, 42);
        expect(result.textureId, 7);
        expect(result.previewSize, const Size(1920, 1080));
      },
    );

    test('initialize / dispose send only the handle', () async {
      handle((_) => null);

      await backend.initialize(11);
      await backend.disposeInstance(11);

      expect(calls.map((c) => c.method).toList(), ['initialize', 'dispose']);
      expect(calls.every((c) => (c.arguments as Map)['handle'] == 11), isTrue);
    });

    test('setDescription returns previewSize + rotation', () async {
      handle(
        (_) => {
          'previewSize': {'width': 1280, 'height': 720},
          'previewRotationQuarterTurns': 1,
        },
      );

      final r = await backend.setDescription(7, 'next');

      expect(calls.single.method, 'setDescription');
      expect(calls.single.arguments, {'handle': 7, 'cameraId': 'next'});
      expect(r.previewSize, const Size(1280, 720));
      expect(r.previewRotationQuarterTurns, 1);
    });

    test('setFlashMode encodes the enum', () async {
      handle((_) => null);

      await backend.setFlashMode(3, XFlashMode.always);
      await backend.setFlashMode(3, XFlashMode.off);

      expect(calls.map((c) => (c.arguments as Map)['mode']).toList(), [
        'always',
        'off',
      ]);
    });

    test(
      'lock/unlockCaptureOrientation encode the orientation string',
      () async {
        handle((_) => null);

        await backend.lockCaptureOrientation(5, DeviceOrientation.portraitUp);
        await backend.lockCaptureOrientation(
          5,
          DeviceOrientation.landscapeLeft,
        );
        await backend.lockCaptureOrientation(
          5,
          DeviceOrientation.landscapeRight,
        );
        await backend.lockCaptureOrientation(5, DeviceOrientation.portraitDown);
        await backend.unlockCaptureOrientation(5);

        expect(
          calls
              .take(4)
              .map((c) => (c.arguments as Map)['orientation'])
              .toList(),
          ['portraitUp', 'landscapeLeft', 'landscapeRight', 'portraitDown'],
        );
        expect(calls.last.method, 'unlockCaptureOrientation');
      },
    );

    test(
      'takePicture sends snapshotOrientation and decodes the file path',
      () async {
        handle((_) => {'path': '/tmp/a.jpg'});

        final file = await backend.takePicture(
          9,
          DeviceOrientation.landscapeLeft,
        );

        expect(calls.single.method, 'takePicture');
        expect(calls.single.arguments, {
          'handle': 9,
          'snapshotOrientation': 'landscapeLeft',
        });
        expect(file.path, '/tmp/a.jpg');
      },
    );

    test('startVideoRecording sends snapshotOrientation', () async {
      handle((_) => null);

      await backend.startVideoRecording(9, DeviceOrientation.landscapeRight);

      expect(calls.single.method, 'startVideoRecording');
      expect(calls.single.arguments, {
        'handle': 9,
        'snapshotOrientation': 'landscapeRight',
      });
    });

    test('stopVideoRecording decodes the file path', () async {
      handle((_) => {'path': '/tmp/v.mp4'});

      final file = await backend.stopVideoRecording(9);

      expect(calls.single.method, 'stopVideoRecording');
      expect(file.path, '/tmp/v.mp4');
    });

    test(
      'events stream filters by handle and decodes diagnostic events',
      () async {
        const eventsChannel = EventChannel('ux/camera/events');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

        messenger.setMockStreamHandler(
          eventsChannel,
          MockStreamHandler.inline(
            onListen: (_, sink) {
              sink.success({
                'event': 'diagnostic',
                'handle': 4,
                'message': 'video input added',
              });
              sink.success({
                'event': 'diagnostic',
                'handle': 7,
                'message': 'audio input added sr=44100 ch=1',
              });
              sink.endOfStream();
            },
          ),
        );
        addTearDown(() => messenger.setMockStreamHandler(eventsChannel, null));

        final received = <XCameraEvent>[];
        await backend.events(4).forEach(received.add);

        expect(received, hasLength(1));
        final e = received.single as XCameraDiagnostic;
        expect(e.handle, 4);
        expect(e.message, 'video input added');
      },
    );

    test('audioPermissionStatus + openSettings round-trip', () async {
      var permissionReply = true;
      handle((call) {
        if (call.method == 'audioPermissionStatus') return permissionReply;
        if (call.method == 'openSettings') return null;
        return null;
      });

      expect(await backend.audioPermissionGranted(), isTrue);
      permissionReply = false;
      expect(await backend.audioPermissionGranted(), isFalse);
      await backend.openSettings();

      expect(calls.map((c) => c.method).toList(), [
        'audioPermissionStatus',
        'audioPermissionStatus',
        'openSettings',
      ]);
    });

    test(
      'camera authorization uses handle-free calls without audio or sessions',
      () async {
        var granted = false;
        handle((call) {
          expect(call.arguments, isNull);
          if (call.method == 'requestCameraPermission') granted = true;
          return granted;
        });

        expect(await backend.cameraPermissionGranted(), isFalse);
        expect(await backend.requestCameraPermission(), isTrue);
        expect(await backend.cameraPermissionGranted(), isTrue);
        granted = false;
        handle((call) => false);
        expect(await backend.requestCameraPermission(), isFalse);
        expect(calls.map((call) => call.method), [
          'cameraPermissionStatus',
          'requestCameraPermission',
          'cameraPermissionStatus',
          'requestCameraPermission',
        ]);
      },
    );

    test('camera permission errors retain platform code and message', () async {
      handle(
        (_) => throw PlatformException(
          code: 'in_progress',
          message: 'another permission request is in flight',
        ),
      );
      final error = throwsA(
        isA<XCameraException>()
            .having((e) => e.code, 'code', 'in_progress')
            .having(
              (e) => e.description,
              'description',
              'another permission request is in flight',
            ),
      );

      await expectLater(backend.cameraPermissionGranted(), error);
      await expectLater(backend.requestCameraPermission(), error);
    });

    test(
      'requestAudioPermission preserves the microphone channel operation',
      () async {
        handle((_) => true);
        expect(await backend.requestAudioPermission(), isTrue);
        expect(calls.single.method, 'requestAudioPermission');
        expect(calls.single.arguments, isNull);
      },
    );

    test(
      'PlatformException maps to XCameraException carrying code/message',
      () async {
        handle(
          (_) => throw PlatformException(
            code: 'device_busy',
            message: 'front camera in use',
          ),
        );

        await expectLater(
          backend.initialize(1),
          throwsA(
            isA<XCameraException>()
                .having((e) => e.code, 'code', 'device_busy')
                .having(
                  (e) => e.description,
                  'description',
                  'front camera in use',
                ),
          ),
        );
      },
    );
  });
}
