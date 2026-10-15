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
  /// Binds the cameras this backend reports and the canned results its
  /// capture calls return.
  FakeXCameraBackend({
    List<XCameraDescription> cameras = const [],
    this.previewSize = const Size(1920, 1080),
    this.picturePath = '/tmp/fake_picture.jpg',
    this.videoPath = '/tmp/fake_video.mp4',
  }) : cameras = List.unmodifiable(cameras);

  // ---- captured calls ---------------------------------------------

  /// Arguments of every [create] call, in order.
  final List<({String cameraId, bool enableAudio, XResolutionPreset preset})>
  createCalls = [];

  /// Handles passed to [initialize], in order.
  final List<int> initializeCalls = [];

  /// Handles passed to [disposeInstance], in order.
  final List<int> disposeCalls = [];

  /// Arguments of every [setDescription] call, in order.
  final List<({int handle, String cameraId})> setDescriptionCalls = [];

  /// Arguments of every [setFlashMode] call, in order.
  final List<({int handle, XFlashMode mode})> setFlashModeCalls = [];

  /// Arguments of every [lockCaptureOrientation] call, in order.
  final List<({int handle, DeviceOrientation orientation})>
  lockCaptureOrientationCalls = [];

  /// Handles passed to [unlockCaptureOrientation], in order.
  final List<int> unlockCaptureOrientationCalls = [];

  /// Arguments of every [takePicture] call, in order.
  final List<({int handle, DeviceOrientation snapshotOrientation})>
  takePictureCalls = [];

  /// Arguments of every [startVideoRecording] call, in order.
  final List<({int handle, DeviceOrientation snapshotOrientation})>
  startVideoRecordingCalls = [];

  /// Handles passed to [stopVideoRecording], in order.
  final List<int> stopVideoRecordingCalls = [];

  /// How many times [availableCameras] has been called.
  int availableCamerasCalls = 0;

  // ---- configurable returns ---------------------------------------

  /// Cameras returned by [availableCameras]. Mutable so tests can swap
  /// the set between assertions.
  List<XCameraDescription> cameras;

  /// Preview size every [create] reports.
  Size previewSize;

  /// Path every [takePicture] resolves to.
  String picturePath;

  /// Path every [stopVideoRecording] resolves to.
  String videoPath;

  /// If non-null, [create] throws this exception instead of returning
  /// a result — exercises permission denial / device busy paths.
  XCameraException? createError;

  /// Optional override; set to throw on any particular method to
  /// drive failure paths.
  XCameraException? initializeError;

  /// If non-null, [takePicture] throws this instead of returning a file.
  XCameraException? takePictureError;

  /// If non-null, [startVideoRecording] throws this.
  XCameraException? startVideoRecordingError;

  /// If non-null, [stopVideoRecording] throws this.
  XCameraException? stopVideoRecordingError;

  /// Authorization returned by [cameraPermissionGranted].
  bool cameraPermission = true;

  /// Authorization returned and stored by [requestCameraPermission].
  bool requestCameraPermissionResult = true;

  /// Failure returned instead of the configured authorization.
  XCameraException? cameraPermissionError;

  /// Request failure that leaves authorization unchanged.
  XCameraException? requestCameraPermissionError;

  /// Number of camera authorization queries.
  int cameraPermissionCalls = 0;

  /// Number of explicit camera authorization requests.
  int requestCameraPermissionCalls = 0;

  /// Audio permission state returned by [audioPermissionGranted].
  /// Tests mutate this to drive the mic-permission UI banner.
  bool audioPermission = true;

  /// How many times [audioPermissionGranted] has been called.
  int audioPermissionCalls = 0;

  /// How many times [openSettings] has been called.
  int openSettingsCalls = 0;

  /// How many times [requestAudioPermission] has been called.
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

  /// Pushes a session error for [handle].
  void emitSessionError(int handle, String code, [String? description]) {
    _controllerFor(handle).add(XCameraSessionError(handle, code, description));
  }

  /// Pushes a session interruption for [handle].
  void emitSessionInterrupted(int handle, String reason) {
    _controllerFor(handle).add(XCameraSessionInterrupted(handle, reason));
  }

  /// Pushes a session resume for [handle].
  void emitSessionResumed(int handle) {
    _controllerFor(handle).add(XCameraSessionResumed(handle));
  }

  /// Pushes a recorder diagnostic for [handle].
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
    takePictureCalls.add((
      handle: handle,
      snapshotOrientation: snapshotOrientation,
    ));
    final err = takePictureError;
    if (err != null) throw err;
    return XFile(picturePath);
  }

  @override
  Future<void> startVideoRecording(
    int handle,
    DeviceOrientation snapshotOrientation,
  ) async {
    startVideoRecordingCalls.add((
      handle: handle,
      snapshotOrientation: snapshotOrientation,
    ));
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
  Future<bool> cameraPermissionGranted() async {
    cameraPermissionCalls += 1;
    final error = cameraPermissionError;
    if (error != null) throw error;
    return cameraPermission;
  }

  @override
  Future<bool> requestCameraPermission() async {
    requestCameraPermissionCalls += 1;
    final error = requestCameraPermissionError;
    if (error != null) throw error;
    cameraPermission = requestCameraPermissionResult;
    return cameraPermission;
  }

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
