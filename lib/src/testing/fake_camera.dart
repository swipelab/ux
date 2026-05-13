import 'dart:async';
import 'dart:ui' show Size;

import 'package:flutter/services.dart';
import 'package:ux/src/camera/camera.dart';
import 'package:ux/src/camera/camera_backend.dart';
import 'package:ux/src/file.dart' show UxFile;

/// In-memory backend for [UxCameraController] tests. Swap in via
/// `UxCameraBackend.instance = FakeUxCameraBackend(...)` before any UI
/// mounts; restore with `UxCameraBackend.instance =
/// MethodChannelUxCameraBackend()` in `tearDown`.
///
/// Captures every call into per-method lists for assertions, and lets
/// tests drive events deterministically via [emitOrientationChanged]
/// and friends.
class FakeUxCameraBackend implements UxCameraBackend {
  FakeUxCameraBackend({
    List<UxCameraDescription> cameras = const [],
    this.previewSize = const Size(1920, 1080),
    this.picturePath = '/tmp/fake_picture.jpg',
    this.videoPath = '/tmp/fake_video.mp4',
  }) : cameras = List.unmodifiable(cameras);

  // ---- captured calls ---------------------------------------------

  final List<({String cameraId, bool enableAudio, UxResolutionPreset preset})>
      createCalls = [];
  final List<int> initializeCalls = [];
  final List<int> disposeCalls = [];
  final List<({int handle, String cameraId})> setDescriptionCalls = [];
  final List<({int handle, UxFlashMode mode})> setFlashModeCalls = [];
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
  List<UxCameraDescription> cameras;
  Size previewSize;
  String picturePath;
  String videoPath;

  /// If non-null, [create] throws this exception instead of returning
  /// a result — exercises permission denial / device busy paths.
  UxCameraException? createError;

  /// Optional override; set to throw on any particular method to
  /// drive failure paths.
  UxCameraException? initializeError;
  UxCameraException? takePictureError;
  UxCameraException? startVideoRecordingError;
  UxCameraException? stopVideoRecordingError;

  // ---- internal ---------------------------------------------------

  int _nextHandle = 1;
  int _nextTextureId = 100;
  final Map<int, StreamController<UxCameraEvent>> _eventControllers = {};

  StreamController<UxCameraEvent> _controllerFor(int handle) {
    return _eventControllers.putIfAbsent(
      handle,
      () => StreamController<UxCameraEvent>.broadcast(),
    );
  }

  // ---- event injection --------------------------------------------

  /// Push a `deviceOrientationChanged` event for [handle]. The
  /// subscribed controller will update its `value.deviceOrientation`.
  void emitOrientationChanged(int handle, DeviceOrientation orientation) {
    _controllerFor(handle)
        .add(UxCameraDeviceOrientationChanged(handle, orientation));
  }

  void emitSessionError(int handle, String code, [String? description]) {
    _controllerFor(handle).add(UxCameraSessionError(handle, code, description));
  }

  void emitSessionInterrupted(int handle, String reason) {
    _controllerFor(handle).add(UxCameraSessionInterrupted(handle, reason));
  }

  void emitSessionResumed(int handle) {
    _controllerFor(handle).add(UxCameraSessionResumed(handle));
  }

  // ---- UxCameraBackend impl --------------------------------------

  @override
  Future<List<UxCameraDescription>> availableCameras() async {
    availableCamerasCalls += 1;
    return cameras;
  }

  @override
  Future<UxCameraCreateResult> create({
    required String cameraId,
    required bool enableAudio,
    required UxResolutionPreset preset,
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
    return UxCameraCreateResult(
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
  Future<Size> setDescription(int handle, String cameraId) async {
    setDescriptionCalls.add((handle: handle, cameraId: cameraId));
    return previewSize;
  }

  @override
  Future<void> setFlashMode(int handle, UxFlashMode mode) async {
    setFlashModeCalls.add((handle: handle, mode: mode));
  }

  @override
  Future<void> lockCaptureOrientation(
    int handle,
    DeviceOrientation orientation,
  ) async {
    lockCaptureOrientationCalls
        .add((handle: handle, orientation: orientation));
  }

  @override
  Future<void> unlockCaptureOrientation(int handle) async {
    unlockCaptureOrientationCalls.add(handle);
  }

  @override
  Future<UxFile> takePicture(
    int handle,
    DeviceOrientation snapshotOrientation,
  ) async {
    takePictureCalls
        .add((handle: handle, snapshotOrientation: snapshotOrientation));
    final err = takePictureError;
    if (err != null) throw err;
    return UxFile(picturePath);
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
  Future<UxFile> stopVideoRecording(int handle) async {
    stopVideoRecordingCalls.add(handle);
    final err = stopVideoRecordingError;
    if (err != null) throw err;
    return UxFile(videoPath);
  }

  @override
  Stream<UxCameraEvent> events(int handle) => _controllerFor(handle).stream;
}
