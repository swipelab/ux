import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/ux.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MethodChannelUxCameraBackend — arg/return parsing', () {
    const channel = MethodChannel('ux/camera');

    late MethodChannelUxCameraBackend backend;
    late List<MethodCall> calls;

    setUp(() {
      backend = MethodChannelUxCameraBackend();
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
      handle((_) => [
            {'id': 'a', 'lens': 'front', 'sensorOrientation': 270},
            {'id': 'b', 'lens': 'back', 'sensorOrientation': 90},
          ]);

      final result = await backend.availableCameras();

      expect(calls.single.method, 'availableCameras');
      expect(result, [
        const UxCameraDescription(
            id: 'a', lens: UxCameraLens.front, sensorOrientation: 270),
        const UxCameraDescription(
            id: 'b', lens: UxCameraLens.back, sensorOrientation: 90),
      ]);
    });

    test('create sends cameraId/enableAudio/preset and decodes the tuple',
        () async {
      handle((_) => {
            'handle': 42,
            'textureId': 7,
            'previewSize': {'width': 1920, 'height': 1080},
          });

      final result = await backend.create(
        cameraId: 'cam-1',
        enableAudio: true,
        preset: UxResolutionPreset.high,
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
    });

    test('initialize / dispose send only the handle', () async {
      handle((_) => null);

      await backend.initialize(11);
      await backend.disposeInstance(11);

      expect(calls.map((c) => c.method).toList(), ['initialize', 'dispose']);
      expect(calls.every((c) => (c.arguments as Map)['handle'] == 11), isTrue);
    });

    test('setDescription returns the new previewSize', () async {
      handle((_) => {
            'previewSize': {'width': 1280, 'height': 720},
          });

      final size = await backend.setDescription(7, 'next');

      expect(calls.single.method, 'setDescription');
      expect(calls.single.arguments, {'handle': 7, 'cameraId': 'next'});
      expect(size, const Size(1280, 720));
    });

    test('setFlashMode encodes the enum', () async {
      handle((_) => null);

      await backend.setFlashMode(3, UxFlashMode.always);
      await backend.setFlashMode(3, UxFlashMode.off);

      expect(calls.map((c) => (c.arguments as Map)['mode']).toList(),
          ['always', 'off']);
    });

    test('lock/unlockCaptureOrientation encode the orientation string',
        () async {
      handle((_) => null);

      await backend.lockCaptureOrientation(5, DeviceOrientation.portraitUp);
      await backend.lockCaptureOrientation(5, DeviceOrientation.landscapeLeft);
      await backend.lockCaptureOrientation(5, DeviceOrientation.landscapeRight);
      await backend.lockCaptureOrientation(5, DeviceOrientation.portraitDown);
      await backend.unlockCaptureOrientation(5);

      expect(
        calls.take(4).map((c) => (c.arguments as Map)['orientation']).toList(),
        ['portraitUp', 'landscapeLeft', 'landscapeRight', 'portraitDown'],
      );
      expect(calls.last.method, 'unlockCaptureOrientation');
    });

    test('takePicture sends snapshotOrientation and decodes the file path',
        () async {
      handle((_) => {'path': '/tmp/a.jpg'});

      final file = await backend.takePicture(
          9, DeviceOrientation.landscapeLeft);

      expect(calls.single.method, 'takePicture');
      expect(calls.single.arguments,
          {'handle': 9, 'snapshotOrientation': 'landscapeLeft'});
      expect(file.path, '/tmp/a.jpg');
    });

    test('startVideoRecording sends snapshotOrientation', () async {
      handle((_) => null);

      await backend.startVideoRecording(9, DeviceOrientation.landscapeRight);

      expect(calls.single.method, 'startVideoRecording');
      expect(calls.single.arguments,
          {'handle': 9, 'snapshotOrientation': 'landscapeRight'});
    });

    test('stopVideoRecording decodes the file path', () async {
      handle((_) => {'path': '/tmp/v.mp4'});

      final file = await backend.stopVideoRecording(9);

      expect(calls.single.method, 'stopVideoRecording');
      expect(file.path, '/tmp/v.mp4');
    });

    test('PlatformException maps to UxCameraException carrying code/message',
        () async {
      handle((_) => throw PlatformException(
            code: 'device_busy',
            message: 'front camera in use',
          ));

      await expectLater(
        backend.initialize(1),
        throwsA(isA<UxCameraException>()
            .having((e) => e.code, 'code', 'device_busy')
            .having((e) => e.description, 'description', 'front camera in use')),
      );
    });
  });
}
