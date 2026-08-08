import 'dart:async';

import 'package:flutter/services.dart';
import 'package:ux/src/camera/camera.dart';
import 'package:ux/src/camera/camera_backend.dart';
import 'package:ux/src/file.dart' show XFile;

/// In-memory backend for [XCameraController] tests. Swap in via
/// `XCameraBackend.instance = FakeXCameraBackend(...)` before any UI
/// mounts; restore with `XCameraBackend.instance =
/// MethodChannelXCameraBackend()` in `tearDown`.
///
/// Captures every call into per-method lists for assertions, and lets
/// tests drive events deterministically via [emitOrientationChanged]
/// and friends.
class FakeXCameraBackend implements XCameraBackend {
  FakeXCameraBackend({
    List<XCameraDescription> cameras = const [],
    this.previewSize = const Size(1920, 1080),
    this.picturePath = '/tmp/fake_picture.jpg',
    this.videoPath = '/tmp/fake_video.mp4',
  }) : cameras = List.unmodifiable(cameras);

  // ---- captured calls ---------------------------------------------

  final List<({String cameraId, bool enableAudio, XResolutionPreset preset})>
      createCalls = [];
  final List<int> initializeCalls = [];
  final List<int> disposeCalls = [];
  final List<({int handle, String cameraId})> setDescriptionCalls = [];
  final List<({int handle, XFlashMode mode})> setFlashModeCalls = [];
  final List<({int handle, DeviceOrientation orientation})>
      lockCaptureOrientationCalls = [];
  final List<int> unlockCaptureOrientationCalls = [];
  final List<({int handle, DeviceOrientation snapshotOrientation})>
      takePictureCalls = [];
  final List<({int handle, DeviceOrientation snapshotOrientation})>
      startVideoRecordingCalls = [];
  final List<int> stopVideoRecordingCalls = [];
  int availableCamerasCalls = 0;

  // ---- configurable returns ---------------------------------------

  /// Cameras returned by [availableCameras]. Mutable so tests can swap
  /// the set between assertions.
  List<XCameraDescription> cameras;
  Size previewSize;
  String picturePath;
  String videoPath;

  /// If non-null, [create] throws this exception instead of returning
  /// a result — exercises permission denial / device busy paths.
  XCameraException? createError;

  /// Optional override; set to throw on any particular method to
  /// drive failure paths.
  XCameraException? initializeError;
  XCameraException? takePictureError;
  XCameraException? startVideoRecordingError;
  XCameraException? stopVideoRecordingError;

  /// Audio permission state returned by [audioPermissionGranted].
  /// Tests mutate this to drive the mic-permission UI banner.
  bool audioPermission = true;
  int audioPermissionCalls = 0;
  int openSettingsCalls = 0;
  int requestAudioPermissionCalls = 0;

  /// Result returned by [requestAudioPermission]. Tests mutate to
  /// exercise grant / permanent-denial paths.
  bool requestAudioPermissionResult = true;

  // ---- internal ---------------------------------------------------

  int _nextHandle = 1;
  int _nextTextureId = 100;
  final Map<int, StreamController<XCameraEvent>> _eventControllers = {};

  StreamController<XCameraEvent> _controllerFor(int handle) {
    return _eventControllers.putIfAbsent(
      handle,
      () => StreamController<XCameraEvent>.broadcast(),
    );
  }

  // ---- event injection --------------------------------------------

  /// Push a `deviceOrientationChanged` event for [handle]. The
  /// subscribed controller will update its `value.deviceOrientation`.
  void emitOrientationChanged(int handle, DeviceOrientation orientation) {
    _controllerFor(handle)
        .add(XCameraDeviceOrientationChanged(handle, orientation));
  }

  void emitSessionError(int handle, String code, [String? description]) {
    _controllerFor(handle).add(XCameraSessionError(handle, code, description));
  }

  void emitSessionInterrupted(int handle, String reason) {
    _controllerFor(handle).add(XCameraSessionInterrupted(handle, reason));
  }

  void emitSessionResumed(int handle) {
    _controllerFor(handle).add(XCameraSessionResumed(handle));
  }

  void emitDiagnostic(int handle, String message) {
    _controllerFor(handle).add(XCameraDiagnostic(handle, message));
  }

  // ---- XCameraBackend impl --------------------------------------

  @override
  Future<List<XCameraDescription>> availableCameras() async {
    availableCamerasCalls += 1;
    return cameras;
  }

  @override
  Future<XCameraCreateResult> create({
    required String cameraId,
    required bool enableAudio,
    required XResolutionPreset preset,
  }) async {
    createCalls.add((
      cameraId: cameraId,
      enableAudio: enableAudio,
      preset: preset,
    ));
    final err = createError;
    if (err != null) throw err;
    final handle = _nextHandle++;
    final textureId = _nextTextureId++;
    return XCameraCreateResult(
      handle: handle,
      textureId: textureId,
      previewSize: previewSize,
    );
  }

  @override
  Future<void> initialize(int handle) async {
    initializeCalls.add(handle);
    final err = initializeError;
    if (err != null) throw err;
  }

  @override
  Future<void> disposeInstance(int handle) async {
    disposeCalls.add(handle);
    await _eventControllers.remove(handle)?.close();
  }

  @override
  Future<({Size previewSize, int previewRotationQuarterTurns})> setDescription(
    int handle,
    String cameraId,
  ) async {
    setDescriptionCalls.add((handle: handle, cameraId: cameraId));
    return (previewSize: previewSize, previewRotationQuarterTurns: 0);
  }

  /// Push a `previewSizeChanged` event for [handle]. Tests that need
  /// to simulate Android's async preview-size resolve drive this.
  void emitPreviewSizeChanged(int handle, Size size) {
    _controllerFor(handle).add(XCameraPreviewSizeChanged(handle, size));
  }

  @override
  Future<void> setFlashMode(int handle, XFlashMode mode) async {
    setFlashModeCalls.add((handle: handle, mode: mode));
  }

  @override
  Future<void> lockCaptureOrientation(
    int handle,
    DeviceOrientation orientation,
  ) async {
    lockCaptureOrientationCalls.add((handle: handle, orientation: orientation));
  }

  @override
  Future<void> unlockCaptureOrientation(int handle) async {
    unlockCaptureOrientationCalls.add(handle);
  }

  @override
  Future<XFile> takePicture(
    int handle,
    DeviceOrientation snapshotOrientation,
  ) async {
    takePictureCalls
        .add((handle: handle, snapshotOrientation: snapshotOrientation));
    final err = takePictureError;
    if (err != null) throw err;
    return XFile(picturePath);
  }

  @override
  Future<void> startVideoRecording(
    int handle,
    DeviceOrientation snapshotOrientation,
  ) async {
    startVideoRecordingCalls
        .add((handle: handle, snapshotOrientation: snapshotOrientation));
    final err = startVideoRecordingError;
    if (err != null) throw err;
  }

  @override
  Future<XFile> stopVideoRecording(int handle) async {
    stopVideoRecordingCalls.add(handle);
    final err = stopVideoRecordingError;
    if (err != null) throw err;
    return XFile(videoPath);
  }

  @override
  Stream<XCameraEvent> events(int handle) => _controllerFor(handle).stream;

  @override
  Future<bool> audioPermissionGranted() async {
    audioPermissionCalls += 1;
    return audioPermission;
  }

  @override
  Future<bool> requestAudioPermission() async {
    requestAudioPermissionCalls += 1;
    if (requestAudioPermissionResult) audioPermission = true;
    return requestAudioPermissionResult;
  }

  @override
  Future<void> openSettings() async {
    openSettingsCalls += 1;
  }
}
