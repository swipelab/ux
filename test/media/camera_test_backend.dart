import 'dart:async';

import 'package:flutter/services.dart';
import 'package:ux/camera.dart';
import 'package:ux/testing.dart';

const frontCamera = XCameraDescription(
  id: 'front',
  lens: XCameraLens.front,
  sensorOrientation: 270,
);
const backCamera = XCameraDescription(
  id: 'back',
  lens: XCameraLens.back,
  sensorOrientation: 90,
);

class CameraTestBackend extends FakeXCameraBackend {
  CameraTestBackend() : super(cameras: const [frontCamera, backCamera]);

  Completer<void>? discoveryGate;
  Completer<void>? createGate;
  Completer<void>? initializeGate;
  Completer<void>? descriptionGate;
  Completer<void>? recordingGate;
  XCameraException? lockError;
  bool failAudioInitialization = false;
  final liveHandles = <int>{};
  final audioHandles = <int>{};
  int listeners = 0;
  final _streams = <int, StreamController<XCameraEvent>>{};

  @override
  Future<List<XCameraDescription>> availableCameras() async {
    await discoveryGate?.future;
    return super.availableCameras();
  }

  @override
  Future<XCameraCreateResult> create({
    required String cameraId,
    required bool enableAudio,
    required XResolutionPreset preset,
  }) async {
    final result = await super.create(
      cameraId: cameraId,
      enableAudio: enableAudio,
      preset: preset,
    );
    liveHandles.add(result.handle);
    if (enableAudio) audioHandles.add(result.handle);
    await createGate?.future;
    return result;
  }

  @override
  Future<void> initialize(int handle) async {
    await super.initialize(handle);
    await initializeGate?.future;
    if (failAudioInitialization && audioHandles.contains(handle)) {
      throw const XCameraException('audio_busy');
    }
  }

  @override
  Future<void> disposeInstance(int handle) async {
    await _streams.remove(handle)?.close();
    await super.disposeInstance(handle);
    liveHandles.remove(handle);
  }

  @override
  Stream<XCameraEvent> events(int handle) => _streams
      .putIfAbsent(
        handle,
        () => StreamController<XCameraEvent>.broadcast(
          onListen: () => listeners++,
          onCancel: () => listeners--,
        ),
      )
      .stream;

  @override
  Future<({Size previewSize, int previewRotationQuarterTurns})> setDescription(
    int handle,
    String cameraId,
  ) async {
    await descriptionGate?.future;
    return super.setDescription(handle, cameraId);
  }

  @override
  Future<void> lockCaptureOrientation(
    int handle,
    DeviceOrientation orientation,
  ) async {
    await super.lockCaptureOrientation(handle, orientation);
    if (lockError case final error?) throw error;
  }

  @override
  Future<void> startVideoRecording(
    int handle,
    DeviceOrientation snapshotOrientation,
  ) async {
    await super.startVideoRecording(handle, snapshotOrientation);
    await recordingGate?.future;
  }
}
