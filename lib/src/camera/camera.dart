import 'dart:async';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Widget;

import '../file.dart' show UxFile;
import '../log.dart' show Log;
import '../sensor.dart' show UxSensor;
import 'camera_backend.dart';
import 'camera_preview.dart' show UxCameraPreview;

final _log = Log.tag('camera');

/// Describes a camera device on the system. Returned by
/// [uxAvailableCameras]; passed to [UxCameraController] to bind a
/// specific lens.
class UxCameraDescription {
  const UxCameraDescription({
    required this.id,
    required this.lens,
    required this.sensorOrientation,
  });

  /// Opaque platform handle — `AVCaptureDevice.uniqueID` on iOS,
  /// CameraX camera id on Android. Treat as a blob; only the plugin
  /// interprets it.
  final String id;

  final UxCameraLens lens;

  /// Clockwise rotation in degrees (0/90/180/270) from the camera
  /// sensor's natural orientation to the device's portrait-up
  /// orientation. Used by post-capture transforms outside this
  /// module (e.g. `normalizeCameraCapture`).
  final int sensorOrientation;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UxCameraDescription &&
          other.id == id &&
          other.lens == lens &&
          other.sensorOrientation == sensorOrientation;

  @override
  int get hashCode => Object.hash(id, lens, sensorOrientation);
}

enum UxCameraLens { front, back }

/// Resolution preset for both photo and video. Single value today
/// (`high`); the enum exists so future presets can land without
/// breaking call sites.
enum UxResolutionPreset { high }

/// Flash mode applied to the next still capture. Only the two values
/// the chat composer actually uses today.
enum UxFlashMode { off, always }

/// Immutable snapshot of a [UxCameraController]'s state, broadcast to
/// listeners. Updated on lifecycle transitions and on device-
/// orientation events from the native side.
class UxCameraValue {
  const UxCameraValue({
    required this.description,
    this.previewSize,
    this.isInitialized = false,
    this.isRecordingVideo = false,
    this.deviceOrientation = DeviceOrientation.portraitUp,
    this.enableAudio = false,
    this.audioPermissionGranted = false,
    this.errorDescription,
  });

  factory UxCameraValue.uninitialized(UxCameraDescription d) =>
      UxCameraValue(description: d);

  final UxCameraDescription description;

  /// Pixel dimensions of the active video format, in the camera
  /// sensor's natural orientation (so for typical phone sensors this
  /// is landscape — `1920×1080` etc.). Null until [isInitialized].
  final Size? previewSize;

  final bool isInitialized;
  final bool isRecordingVideo;

  /// Physical orientation reported by the native side's orientation
  /// listener. Independent of any UI lock; used by [_Rotating] widgets
  /// in `camera_page.dart` so icons flip while the preview stays
  /// portrait.
  final DeviceOrientation deviceOrientation;

  final bool enableAudio;

  /// True iff the user has granted microphone access. Updated when
  /// the controller initialises and on
  /// [UxCameraController.refreshAudioPermission]. Independent of
  /// [enableAudio] — a controller can request audio (`enableAudio:
  /// true`) without having permission, in which case recordings have
  /// no audio track and callers should surface a hint.
  final bool audioPermissionGranted;

  /// Set to the last native session error's message when one fires.
  /// Cleared on the next successful state transition.
  final String? errorDescription;

  bool get hasError => errorDescription != null;

  UxCameraValue copyWith({
    UxCameraDescription? description,
    Size? previewSize,
    bool? isInitialized,
    bool? isRecordingVideo,
    DeviceOrientation? deviceOrientation,
    bool? enableAudio,
    bool? audioPermissionGranted,
    Object? errorDescription = _unset,
  }) =>
      UxCameraValue(
        description: description ?? this.description,
        previewSize: previewSize ?? this.previewSize,
        isInitialized: isInitialized ?? this.isInitialized,
        isRecordingVideo: isRecordingVideo ?? this.isRecordingVideo,
        deviceOrientation: deviceOrientation ?? this.deviceOrientation,
        enableAudio: enableAudio ?? this.enableAudio,
        audioPermissionGranted: audioPermissionGranted ?? this.audioPermissionGranted,
        errorDescription: identical(errorDescription, _unset)
            ? this.errorDescription
            : errorDescription as String?,
      );

  static const _unset = Object();
}

/// Throws when a [UxCameraController] call fails on the platform side.
/// Maps from native `FlutterError` codes; see the table in
/// `~/banlu/plans/ux_camera.md` §error-model for the full set.
class UxCameraException implements Exception {
  const UxCameraException(this.code, [this.description]);

  final String code;
  final String? description;

  @override
  String toString() =>
      'UxCameraException($code${description == null ? '' : ': $description'})';
}

/// Enumerate the cameras the platform exposes. Stable for the lifetime
/// of the process; safe to cache the result.
Future<List<UxCameraDescription>> uxAvailableCameras() =>
    UxCameraBackend.instance.availableCameras();

/// Owns one native camera session. Mirrors the surface
/// `package:camera`'s `CameraController` exposes today — every method
/// signature the chat composer touches has a 1:1 here, plus the
/// orientation snapshot is passed explicitly on capture calls.
///
/// Lifecycle: [initialize] → use → [dispose]. After [dispose] every
/// other method throws `UxCameraException("disposed")`.
class UxCameraController extends ValueNotifier<UxCameraValue> {
  UxCameraController(
    UxCameraDescription description,
    this.resolutionPreset, {
    required bool enableAudio,
  }) : super(UxCameraValue(
          description: description,
          enableAudio: enableAudio,
        ));

  final UxResolutionPreset resolutionPreset;

  int? _handle;
  int? _textureId;
  StreamSubscription<UxCameraEvent>? _eventsSub;
  bool _disposed = false;

  UxCameraDescription get description => value.description;
  bool get enableAudio => value.enableAudio;

  /// Texture id once the session has been created (during [initialize]).
  /// Read by [UxCameraPreview]; null before init or after dispose.
  int? get textureId => _textureId;

  /// Configure the native session and begin streaming preview frames.
  ///
  /// Throws if camera or microphone permission is denied, or if another
  /// instance already holds the requested device or the audio session.
  Future<void> initialize() async {
    _throwIfDisposed('initialize');
    try {
      final result = await UxCameraBackend.instance.create(
        cameraId: description.id,
        enableAudio: value.enableAudio,
        preset: resolutionPreset,
      );
      _handle = result.handle;
      _textureId = result.textureId;
      _eventsSub = UxCameraBackend.instance.events(result.handle).listen(
            _onEvent,
            onError: (Object error, StackTrace? stack) {
              value = value.copyWith(errorDescription: error.toString());
            },
          );
      await UxCameraBackend.instance.initialize(result.handle);
      final audioGranted =
          await UxCameraBackend.instance.audioPermissionGranted();
      value = value.copyWith(
        isInitialized: true,
        previewSize: result.previewSize,
        audioPermissionGranted: audioGranted,
      );
    } catch (_) {
      // initialize failed mid-way. The native side may have allocated
      // a handle + claimed the camera/audio. Tear down what we have
      // so the next attempt isn't blocked by a leaked device claim.
      // [_handle] / [_eventsSub] are cleaned by [dispose] which
      // tolerates the partial state.
      await dispose();
      rethrow;
    }
  }

  void _onEvent(UxCameraEvent event) {
    switch (event) {
      case UxCameraDeviceOrientationChanged(:final orientation):
        value = value.copyWith(deviceOrientation: orientation);
      case UxCameraSessionError(:final code, :final description):
        value = value.copyWith(errorDescription: description ?? code);
      case UxCameraSessionInterrupted():
      case UxCameraSessionResumed():
        break;
      case UxCameraDiagnostic(:final message):
        _log.i('recorder: $message');
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final handle = _handle;
    _handle = null;
    final sub = _eventsSub;
    _eventsSub = null;
    if (handle != null) {
      await UxCameraBackend.instance.disposeInstance(handle);
    }
    await sub?.cancel();
    super.dispose();
  }

  /// Switch lenses without tearing down the controller. Blocked while a
  /// recording is in flight — call [stopVideoRecording] first.
  Future<void> setDescription(UxCameraDescription description) async {
    final handle = _requireHandle('setDescription');
    final size = await UxCameraBackend.instance.setDescription(handle, description.id);
    value = value.copyWith(description: description, previewSize: size);
  }

  Future<void> setFlashMode(UxFlashMode mode) async {
    final handle = _requireHandle('setFlashMode');
    await UxCameraBackend.instance.setFlashMode(handle, mode);
  }

  Future<void> lockCaptureOrientation(DeviceOrientation orientation) async {
    final handle = _requireHandle('lockCaptureOrientation');
    await UxCameraBackend.instance.lockCaptureOrientation(handle, orientation);
  }

  Future<void> unlockCaptureOrientation() async {
    final handle = _requireHandle('unlockCaptureOrientation');
    await UxCameraBackend.instance.unlockCaptureOrientation(handle);
  }

  /// Capture a still. [captureOrientation] is the orientation to embed
  /// in the resulting JPEG; defaults to [UxSensor.orientation] read at
  /// call time. Tests pass an explicit value to keep the assertion
  /// deterministic.
  Future<UxFile> takePicture({DeviceOrientation? captureOrientation}) async {
    final handle = _requireHandle('takePicture');
    final orientation = captureOrientation ?? UxSensor.orientation;
    return UxCameraBackend.instance.takePicture(handle, orientation);
  }

  /// Start recording. [captureOrientation] becomes the video file's
  /// rotation transform (iOS: AVAssetWriterInput.transform; Android:
  /// CameraX targetRotation). Defaults to [UxSensor.orientation] —
  /// pass explicitly from tests.
  Future<void> startVideoRecording({
    DeviceOrientation? captureOrientation,
  }) async {
    final handle = _requireHandle('startVideoRecording');
    final orientation = captureOrientation ?? UxSensor.orientation;
    await UxCameraBackend.instance.startVideoRecording(handle, orientation);
    value = value.copyWith(isRecordingVideo: true);
  }

  Future<UxFile> stopVideoRecording() async {
    final handle = _requireHandle('stopVideoRecording');
    final file = await UxCameraBackend.instance.stopVideoRecording(handle);
    value = value.copyWith(isRecordingVideo: false);
    return file;
  }

  /// Re-poll the OS for mic permission state and update
  /// [value.audioPermissionGranted]. Call on
  /// `AppLifecycleState.resumed` to pick up grants made via Settings.
  Future<void> refreshAudioPermission() async {
    _throwIfDisposed('refreshAudioPermission');
    final granted = await UxCameraBackend.instance.audioPermissionGranted();
    if (granted != value.audioPermissionGranted) {
      value = value.copyWith(audioPermissionGranted: granted);
    }
  }

  /// Whether the user has granted mic permission to the app. Static
  /// because the answer is global to the process — useful from UI that
  /// needs the status before any controller has been created (e.g.
  /// the camera page's "Tap to enable mic" banner).
  static Future<bool> audioPermissionGranted() =>
      UxCameraBackend.instance.audioPermissionGranted();

  /// Deep-link into the system Settings page so the user can grant
  /// mic permission. Static because it doesn't depend on any active
  /// controller — useful from the banner tap before the controller
  /// has finished initialising.
  static Future<void> openSystemSettings() =>
      UxCameraBackend.instance.openSettings();

  /// Texture-backed widget that renders the live preview at its parent's
  /// size. Hero-flightable.
  Widget buildPreview() => UxCameraPreview(controller: this);

  int _requireHandle(String op) {
    _throwIfDisposed(op);
    final h = _handle;
    if (h == null) {
      throw const UxCameraException('not_initialized');
    }
    return h;
  }

  void _throwIfDisposed(String op) {
    if (_disposed) {
      throw UxCameraException('disposed', '$op called on a disposed controller');
    }
  }
}
