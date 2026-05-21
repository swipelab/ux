import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ux/testing.dart';
import 'package:ux/ux.dart';

const _front = XCameraDescription(
  id: 'front',
  lens: XCameraLens.front,
  sensorOrientation: 270,
);
const _back = XCameraDescription(
  id: 'back',
  lens: XCameraLens.back,
  sensorOrientation: 90,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeXCameraBackend fake;

  setUp(() {
    fake = FakeXCameraBackend(cameras: const [_front, _back]);
    XCameraBackend.instance = fake;
  });

  tearDown(() {
    XCameraBackend.instance = MethodChannelXCameraBackend();
  });

  test('uxAvailableCameras dispatches through the backend', () async {
    final cameras = await uxAvailableCameras();
    expect(cameras, [_front, _back]);
    expect(fake.availableCamerasCalls, 1);
  });

  test('initialize creates the native instance, subscribes to events, '
      'and reports previewSize / isInitialized', () async {
    final ctrl = XCameraController(_front, XResolutionPreset.high, enableAudio: false);
    addTearDown(ctrl.dispose);

    expect(ctrl.value.isInitialized, isFalse);
    expect(ctrl.value.previewSize, isNull);

    await ctrl.initialize();

    expect(fake.createCalls.single,
        (cameraId: 'front', enableAudio: false, preset: XResolutionPreset.high));
    expect(fake.initializeCalls.single, 1);
    expect(ctrl.textureId, 100);
    expect(ctrl.value.isInitialized, isTrue);
    expect(ctrl.value.previewSize, const Size(1920, 1080));
  });

  test('deviceOrientationChanged events update value.deviceOrientation', () async {
    final ctrl = XCameraController(_front, XResolutionPreset.high, enableAudio: false);
    addTearDown(ctrl.dispose);
    await ctrl.initialize();

    expect(ctrl.value.deviceOrientation, DeviceOrientation.portraitUp);

    fake.emitOrientationChanged(1, DeviceOrientation.landscapeLeft);
    await Future<void>.delayed(Duration.zero);
    expect(ctrl.value.deviceOrientation, DeviceOrientation.landscapeLeft);

    fake.emitOrientationChanged(1, DeviceOrientation.portraitDown);
    await Future<void>.delayed(Duration.zero);
    expect(ctrl.value.deviceOrientation, DeviceOrientation.portraitDown);
  });

  test('diagnostic events route through Log.tag("camera") and do not '
      'mutate value', () async {
    final records = <LogRecord>[];
    final prevSink = Log.sink;
    Log.configure(
      minLevel: LogLevel.info,
      sink: _CapturingSink(records),
      captureCrashes: () {},
    );
    addTearDown(() => Log.configure(sink: prevSink, captureCrashes: () {}));

    final ctrl = XCameraController(_front, XResolutionPreset.high, enableAudio: false);
    addTearDown(ctrl.dispose);
    await ctrl.initialize();

    final beforeValue = ctrl.value;
    fake.emitDiagnostic(1, 'video input added');
    await Future<void>.delayed(Duration.zero);

    expect(ctrl.value, beforeValue);
    final diag = records.singleWhere((r) => r.tag == 'camera');
    expect(diag.level, LogLevel.info);
    expect(diag.message, 'recorder: video input added');
  });

  test('sessionError events surface as value.errorDescription', () async {
    final ctrl = XCameraController(_front, XResolutionPreset.high, enableAudio: false);
    addTearDown(ctrl.dispose);
    await ctrl.initialize();

    fake.emitSessionError(1, 'recorder_failed', 'writer ended');
    await Future<void>.delayed(Duration.zero);
    expect(ctrl.value.errorDescription, 'writer ended');
    expect(ctrl.value.hasError, isTrue);
  });

  test('takePicture passes the explicit captureOrientation through', () async {
    final ctrl = XCameraController(_front, XResolutionPreset.high, enableAudio: false);
    addTearDown(ctrl.dispose);
    await ctrl.initialize();

    final file = await ctrl.takePicture(captureOrientation: DeviceOrientation.landscapeRight);

    expect(file.path, '/tmp/fake_picture.jpg');
    expect(fake.takePictureCalls.single,
        (handle: 1, snapshotOrientation: DeviceOrientation.landscapeRight));
  });

  test('takePicture without captureOrientation falls back to XSensor', () async {
    // XSensor.orientation returns portraitUp under flutter_test (no native sensor).
    final ctrl = XCameraController(_front, XResolutionPreset.high, enableAudio: false);
    addTearDown(ctrl.dispose);
    await ctrl.initialize();

    await ctrl.takePicture();

    expect(fake.takePictureCalls.single,
        (handle: 1, snapshotOrientation: DeviceOrientation.portraitUp));
  });

  test('startVideoRecording flips isRecordingVideo and passes orientation', () async {
    final ctrl = XCameraController(_front, XResolutionPreset.high, enableAudio: true);
    addTearDown(ctrl.dispose);
    await ctrl.initialize();

    await ctrl.startVideoRecording(captureOrientation: DeviceOrientation.landscapeLeft);

    expect(ctrl.value.isRecordingVideo, isTrue);
    expect(fake.startVideoRecordingCalls.single,
        (handle: 1, snapshotOrientation: DeviceOrientation.landscapeLeft));
  });

  test('stopVideoRecording resets isRecordingVideo and returns the file', () async {
    final ctrl = XCameraController(_front, XResolutionPreset.high, enableAudio: true);
    addTearDown(ctrl.dispose);
    await ctrl.initialize();
    await ctrl.startVideoRecording(captureOrientation: DeviceOrientation.landscapeLeft);

    final file = await ctrl.stopVideoRecording();

    expect(ctrl.value.isRecordingVideo, isFalse);
    expect(file.path, '/tmp/fake_video.mp4');
    expect(fake.stopVideoRecordingCalls.single, 1);
  });

  test('previewSizeChanged events update value.previewSize without losing rotation',
      () async {
    final ctrl = XCameraController(_back, XResolutionPreset.high, enableAudio: false);
    addTearDown(ctrl.dispose);
    await ctrl.initialize();

    // Fake create returns Size(1920, 1080); simulate Android's async
    // first-SurfaceRequest landing with a revised resolution.
    expect(ctrl.value.previewSize, const Size(1920, 1080));
    fake.emitPreviewSizeChanged(1, const Size(1280, 720));
    await Future<void>.delayed(Duration.zero);

    expect(ctrl.value.previewSize, const Size(1280, 720));
    expect(ctrl.value.previewRotationQuarterTurns, 0);
  });

  test('setDescription updates value.description and previewSize', () async {
    final ctrl = XCameraController(_front, XResolutionPreset.high, enableAudio: false);
    addTearDown(ctrl.dispose);
    await ctrl.initialize();

    fake.previewSize = const Size(1280, 720);
    await ctrl.setDescription(_back);

    expect(ctrl.value.description, _back);
    expect(ctrl.value.previewSize, const Size(1280, 720));
    expect(fake.setDescriptionCalls.single, (handle: 1, cameraId: 'back'));
  });

  test('setFlashMode forwards to the backend', () async {
    final ctrl = XCameraController(_back, XResolutionPreset.high, enableAudio: false);
    addTearDown(ctrl.dispose);
    await ctrl.initialize();

    await ctrl.setFlashMode(XFlashMode.always);

    expect(fake.setFlashModeCalls.single, (handle: 1, mode: XFlashMode.always));
  });

  test('lockCaptureOrientation / unlockCaptureOrientation forward to backend',
      () async {
    final ctrl = XCameraController(_front, XResolutionPreset.high, enableAudio: false);
    addTearDown(ctrl.dispose);
    await ctrl.initialize();

    await ctrl.lockCaptureOrientation(DeviceOrientation.portraitUp);
    expect(fake.lockCaptureOrientationCalls.single,
        (handle: 1, orientation: DeviceOrientation.portraitUp));

    await ctrl.unlockCaptureOrientation();
    expect(fake.unlockCaptureOrientationCalls.single, 1);
  });

  test('dispose tears down the native instance and is idempotent', () async {
    final ctrl = XCameraController(_front, XResolutionPreset.high, enableAudio: false);
    await ctrl.initialize();

    await ctrl.dispose();
    expect(fake.disposeCalls.single, 1);

    // Second dispose is a no-op (does not call backend again, does not throw).
    await ctrl.dispose();
    expect(fake.disposeCalls, [1]);
  });

  test('calls against a disposed controller throw XCameraException', () async {
    final ctrl = XCameraController(_front, XResolutionPreset.high, enableAudio: false);
    await ctrl.initialize();
    await ctrl.dispose();

    expect(() => ctrl.takePicture(captureOrientation: DeviceOrientation.portraitUp),
        throwsA(isA<XCameraException>().having((e) => e.code, 'code', 'disposed')));
  });

  test('calls before initialize throw XCameraException("not_initialized")',
      () async {
    final ctrl = XCameraController(_front, XResolutionPreset.high, enableAudio: false);
    addTearDown(ctrl.dispose);

    expect(() => ctrl.setFlashMode(XFlashMode.off),
        throwsA(isA<XCameraException>().having((e) => e.code, 'code', 'not_initialized')));
  });

  test('multi-instance: two controllers get distinct handles + textures',
      () async {
    final a = XCameraController(_front, XResolutionPreset.high, enableAudio: false);
    final b = XCameraController(_back, XResolutionPreset.high, enableAudio: false);
    addTearDown(a.dispose);
    addTearDown(b.dispose);

    await a.initialize();
    await b.initialize();

    expect(a.textureId, isNot(b.textureId));
    expect(fake.createCalls.map((c) => c.cameraId), ['front', 'back']);

    // Events route per-handle: orientation update to A doesn't touch B.
    fake.emitOrientationChanged(1, DeviceOrientation.landscapeLeft);
    fake.emitOrientationChanged(2, DeviceOrientation.landscapeRight);
    await Future<void>.delayed(Duration.zero);
    expect(a.value.deviceOrientation, DeviceOrientation.landscapeLeft);
    expect(b.value.deviceOrientation, DeviceOrientation.landscapeRight);
  });

  test('initialize captures audioPermissionGranted into value', () async {
    fake.audioPermission = false;
    final ctrl = XCameraController(_front, XResolutionPreset.high, enableAudio: true);
    addTearDown(ctrl.dispose);

    await ctrl.initialize();

    expect(ctrl.value.audioPermissionGranted, isFalse);
    expect(fake.audioPermissionCalls, 1);
  });

  test('refreshAudioPermission re-polls and updates value', () async {
    fake.audioPermission = false;
    final ctrl = XCameraController(_front, XResolutionPreset.high, enableAudio: true);
    addTearDown(ctrl.dispose);
    await ctrl.initialize();
    expect(ctrl.value.audioPermissionGranted, isFalse);

    fake.audioPermission = true;
    await ctrl.refreshAudioPermission();

    expect(ctrl.value.audioPermissionGranted, isTrue);
    expect(fake.audioPermissionCalls, 2);
  });

  test('openSystemSettings dispatches to the backend', () async {
    await XCameraController.openSystemSettings();
    expect(fake.openSettingsCalls, 1);
  });

  test('requestAudioPermission returns the backend result', () async {
    fake.requestAudioPermissionResult = false;
    expect(await XCameraController.requestAudioPermission(), isFalse);
    expect(fake.requestAudioPermissionCalls, 1);

    fake.requestAudioPermissionResult = true;
    expect(await XCameraController.requestAudioPermission(), isTrue);
    expect(fake.requestAudioPermissionCalls, 2);
  });

  test('initialize propagates XCameraException("permission_denied")', () async {
    fake.createError = const XCameraException('permission_denied', 'camera');
    final ctrl = XCameraController(_front, XResolutionPreset.high, enableAudio: false);
    addTearDown(ctrl.dispose);

    expect(() => ctrl.initialize(),
        throwsA(isA<XCameraException>().having((e) => e.code, 'code', 'permission_denied')));
  });
}

class _CapturingSink extends LogSink {
  _CapturingSink(this.records);

  final List<LogRecord> records;

  @override
  LogLevel get minLevel => LogLevel.trace;

  @override
  void emit(LogRecord record) => records.add(record);
}
