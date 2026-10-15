import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Widget;

import 'package:ux/src/file.dart' show XFile;
import 'package:ux/src/log.dart' show Log;
import 'package:ux/src/sensor.dart' show XSensor;
import 'package:ux/src/camera/camera_backend.dart';
import 'package:ux/src/camera/camera_preview.dart' show XCameraPreview;

final _log = Log.tag('camera');

/// Describes a camera device on the system. Returned by
/// [uxAvailableCameras]; passed to [XCameraController] to bind a
/// specific lens.
class XCameraDescription {
  /// Binds a platform camera id to the lens it drives.
  const XCameraDescription({
    required this.id,
    required this.lens,
    required this.sensorOrientation,
  });

  /// Opaque platform handle — `AVCaptureDevice.uniqueID` on iOS,
  /// CameraX camera id on Android. Treat as a blob; only the plugin
  /// interprets it.
  final String id;

  /// Side of the device this camera faces.
  final XCameraLens lens;

  /// Clockwise rotation in degrees (0/90/180/270) from the camera
  /// sensor's natural orientation to the device's portrait-up
  /// orientation. Used by post-capture transforms outside this
  /// module (e.g. `normalizeCameraCapture`).
  final int sensorOrientation;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is XCameraDescription &&
          other.id == id &&
          other.lens == lens &&
          other.sensorOrientation == sensorOrientation;

  @override
  int get hashCode => Object.hash(id, lens, sensorOrientation);
}

/// Which way a camera faces.
enum XCameraLens {
  /// User-facing camera.
  front,

  /// World-facing camera.
  back,
}

/// Resolution preset for both photo and video. Single value today
/// (`high`); the enum exists so future presets can land without
/// breaking call sites.
enum XResolutionPreset {
  /// Highest preset the device offers for both photo and video.
  high,
}

/// Flash mode applied to the next still capture. Only the two values
/// the chat composer actually uses today.
enum XFlashMode {
  /// The flash never fires.
  off,

  /// The flash fires on every capture.
  always,
}

/// Immutable snapshot of a [XCameraController]'s state, broadcast to
/// listeners. Updated on lifecycle transitions and on device-
/// orientation events from the native side.
class XCameraValue {
  /// Binds a full state snapshot; every field but [description] defaults to
  /// the uninitialized value.
  const XCameraValue({
    required this.description,
    this.previewSize,
    this.isInitialized = false,
    this.isRecordingVideo = false,
    this.deviceOrientation = DeviceOrientation.portraitUp,
    this.enableAudio = false,
    this.audioPermissionGranted = false,
    this.previewRotationQuarterTurns = 0,
    this.errorDescription,
  });

  /// State of a camera bound but not yet initialized.
  factory XCameraValue.uninitialized(XCameraDescription d) =>
      XCameraValue(description: d);

  /// The camera this state describes.
  final XCameraDescription description;

  /// Pixel dimensions of the active video format, in the camera
  /// sensor's natural orientation (so for typical phone sensors this
  /// is landscape — `1920×1080` etc.). Null until [isInitialized].
  final Size? previewSize;

  /// Whether the native session is configured and streaming preview frames.
  final bool isInitialized;

  /// Whether a video recording is in flight.
  final bool isRecordingVideo;

  /// Physical orientation reported by the native side's orientation
  /// listener. Independent of any UI lock; used by [_Rotating] widgets
  /// in `camera_page.dart` so icons flip while the preview stays
  /// portrait.
  final DeviceOrientation deviceOrientation;

  /// Whether the session was asked to capture audio alongside video.
  final bool enableAudio;

  /// True iff the user has granted microphone access. Updated when
  /// the controller initialises and on
  /// [XCameraController.refreshAudioPermission]. Independent of
  /// [enableAudio] — a controller can request audio (`enableAudio:
  /// true`) without having permission, in which case recordings have
  /// no audio track and callers should surface a hint.
  final bool audioPermissionGranted;

  /// Number of 90° clockwise rotations the preview Texture needs so
  /// the sensor frames display upright. On iOS the data output
  /// pre-rotates via `AVCaptureConnection.videoOrientation` and this
  /// is always 0. On Android CameraX delivers sensor-native frames to
  /// the Surface and the consumer rotates — typically 1 for
  /// `sensorOrientation: 90` back cams and 3 for `sensorOrientation:
  /// 270` front cams. Applied inside [XCameraPreview]; consumers
  /// don't read this directly.
  final int previewRotationQuarterTurns;

  /// Set to the last native session error's message when one fires.
  /// Cleared on the next successful state transition.
  final String? errorDescription;

  /// Whether [errorDescription] is set.
  bool get hasError => errorDescription != null;

  /// This snapshot with the given fields replaced. Passing
  /// `errorDescription: null` clears the error; omitting it keeps the
  /// current one.
  XCameraValue copyWith({
    XCameraDescription? description,
    Size? previewSize,
    bool? isInitialized,
    bool? isRecordingVideo,
    DeviceOrientation? deviceOrientation,
    bool? enableAudio,
    bool? audioPermissionGranted,
    int? previewRotationQuarterTurns,
    Object? errorDescription = _unset,
  }) => XCameraValue(
    description: description ?? this.description,
    previewSize: previewSize ?? this.previewSize,
    isInitialized: isInitialized ?? this.isInitialized,
    isRecordingVideo: isRecordingVideo ?? this.isRecordingVideo,
    deviceOrientation: deviceOrientation ?? this.deviceOrientation,
    enableAudio: enableAudio ?? this.enableAudio,
    audioPermissionGranted:
        audioPermissionGranted ?? this.audioPermissionGranted,
    previewRotationQuarterTurns:
        previewRotationQuarterTurns ?? this.previewRotationQuarterTurns,
    errorDescription: identical(errorDescription, _unset)
        ? this.errorDescription
        : errorDescription as String?,
  );

  static const _unset = Object();
}

/// Throws when a [XCameraController] call fails on the platform side.
/// Maps from native `FlutterError` codes; see the table in
/// `~/banlu/plans/ux_camera.md` §error-model for the full set.
class XCameraException implements Exception {
  /// Binds the native error [code] and its optional message.
  const XCameraException(this.code, [this.description]);

  /// Stable identifier of the failure, e.g. `disposed`.
  final String code;

  /// Human-readable detail, where the native side supplied one.
  final String? description;

  @override
  String toString() =>
      'XCameraException($code${description == null ? '' : ': $description'})';
}

/// Enumerate the cameras the platform exposes. Stable for the lifetime
/// of the process; safe to cache the result.
Future<List<XCameraDescription>> uxAvailableCameras() =>
    XCameraBackend.instance.availableCameras();

/// Owns one native camera session. Mirrors the surface
/// `package:camera`'s `CameraController` exposes today — every method
/// signature the chat composer touches has a 1:1 here, plus the
/// orientation snapshot is passed explicitly on capture calls.
///
/// Lifecycle: [initialize] → use → [dispose]. After [dispose] every
/// other method throws `XCameraException("disposed")`.
class XCameraController extends ValueNotifier<XCameraValue> {
  /// Binds a camera and its preset without touching the device; call
  /// [initialize] to open the session.
  XCameraController(
    XCameraDescription description,
    this.resolutionPreset, {
    required bool enableAudio,
  }) : super(XCameraValue(description: description, enableAudio: enableAudio));

  /// Resolution the session is opened at.
  final XResolutionPreset resolutionPreset;

  int? _handle;
  int? _textureId;
  StreamSubscription<XCameraEvent>? _eventsSub;
  bool _disposed = false;

  /// The camera currently bound; changes with [setDescription].
  XCameraDescription get description => value.description;

  /// Whether this session was opened asking for audio.
  bool get enableAudio => value.enableAudio;

  /// Texture id once the session has been created (during [initialize]).
  /// Read by [XCameraPreview]; null before init or after dispose.
  int? get textureId => _textureId;

  /// Configure the native session and begin streaming preview frames.
  ///
  /// Throws if camera or microphone permission is denied, or if another
  /// instance already holds the requested device or the audio session.
  Future<void> initialize() async {
    _throwIfDisposed('initialize');
    try {
      final result = await XCameraBackend.instance.create(
        cameraId: description.id,
        enableAudio: value.enableAudio,
        preset: resolutionPreset,
      );
      _handle = result.handle;
      _textureId = result.textureId;
      _eventsSub = XCameraBackend.instance
          .events(result.handle)
          .listen(
            _onEvent,
            onError: (Object error, StackTrace? stack) {
              value = value.copyWith(errorDescription: error.toString());
            },
          );
      await XCameraBackend.instance.initialize(result.handle);
      final audioGranted = await XCameraBackend.instance
          .audioPermissionGranted();
      value = value.copyWith(
        isInitialized: true,
        previewSize: result.previewSize,
        previewRotationQuarterTurns: result.previewRotationQuarterTurns,
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

  void _onEvent(XCameraEvent event) {
    switch (event) {
      case XCameraDeviceOrientationChanged(:final orientation):
        value = value.copyWith(deviceOrientation: orientation);
      case XCameraSessionError(:final code, :final description):
        value = value.copyWith(errorDescription: description ?? code);
      case XCameraSessionInterrupted():
      case XCameraSessionResumed():
        break;
      case XCameraDiagnostic(:final message):
        _log.i('recorder: $message');
      case XCameraPreviewSizeChanged(:final previewSize):
        value = value.copyWith(previewSize: previewSize);
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
      await XCameraBackend.instance.disposeInstance(handle);
    }
    await sub?.cancel();
    super.dispose();
  }

  /// Switch lenses without tearing down the controller. Blocked while a
  /// recording is in flight — call [stopVideoRecording] first.
  Future<void> setDescription(XCameraDescription description) async {
    final handle = _requireHandle('setDescription');
    final r = await XCameraBackend.instance.setDescription(
      handle,
      description.id,
    );
    value = value.copyWith(
      description: description,
      previewSize: r.previewSize,
      previewRotationQuarterTurns: r.previewRotationQuarterTurns,
    );
  }

  /// Sets the flash mode applied to the next still capture.
  Future<void> setFlashMode(XFlashMode mode) async {
    final handle = _requireHandle('setFlashMode');
    await XCameraBackend.instance.setFlashMode(handle, mode);
  }

  /// Pins captures to [orientation], ignoring how the device is held.
  Future<void> lockCaptureOrientation(DeviceOrientation orientation) async {
    final handle = _requireHandle('lockCaptureOrientation');
    await XCameraBackend.instance.lockCaptureOrientation(handle, orientation);
  }

  /// Returns captures to following the device orientation.
  Future<void> unlockCaptureOrientation() async {
    final handle = _requireHandle('unlockCaptureOrientation');
    await XCameraBackend.instance.unlockCaptureOrientation(handle);
  }

  /// Capture a still. [captureOrientation] is the orientation to embed
  /// in the resulting JPEG; defaults to [XSensor.orientation] read at
  /// call time. Tests pass an explicit value to keep the assertion
  /// deterministic.
  Future<XFile> takePicture({DeviceOrientation? captureOrientation}) async {
    final handle = _requireHandle('takePicture');
    final orientation = captureOrientation ?? XSensor.orientation;
    return XCameraBackend.instance.takePicture(handle, orientation);
  }

  /// Start recording. [captureOrientation] becomes the video file's
  /// rotation transform (iOS: AVAssetWriterInput.transform; Android:
  /// CameraX targetRotation). Defaults to [XSensor.orientation] —
  /// pass explicitly from tests.
  Future<void> startVideoRecording({
    DeviceOrientation? captureOrientation,
  }) async {
    final handle = _requireHandle('startVideoRecording');
    final orientation = captureOrientation ?? XSensor.orientation;
    await XCameraBackend.instance.startVideoRecording(handle, orientation);
    value = value.copyWith(isRecordingVideo: true);
  }

  /// Ends the recording and yields the finished file.
  Future<XFile> stopVideoRecording() async {
    final handle = _requireHandle('stopVideoRecording');
    final file = await XCameraBackend.instance.stopVideoRecording(handle);
    value = value.copyWith(isRecordingVideo: false);
    return file;
  }

  /// Re-poll the OS for mic permission state and update
  /// [value.audioPermissionGranted]. Call on
  /// `AppLifecycleState.resumed` to pick up grants made via Settings.
  Future<void> refreshAudioPermission() async {
    _throwIfDisposed('refreshAudioPermission');
    final granted = await XCameraBackend.instance.audioPermissionGranted();
    if (granted != value.audioPermissionGranted) {
      value = value.copyWith(audioPermissionGranted: granted);
    }
  }

  /// Reads camera authorization without prompting or creating a session.
  static Future<bool> cameraPermissionGranted() =>
      XCameraBackend.instance.cameraPermissionGranted();

  /// Requests camera access, opening Settings when another prompt is unavailable.
  /// Returns current authorization; re-query on foreground return from Settings.
  static Future<bool> requestCameraPermission() =>
      XCameraBackend.instance.requestCameraPermission();

  /// Whether the user has granted mic permission to the app. Static
  /// because the answer is global to the process — useful from UI that
  /// needs the status before any controller has been created (e.g.
  /// the camera page's "Tap to enable mic" banner).
  static Future<bool> audioPermissionGranted() =>
      XCameraBackend.instance.audioPermissionGranted();

  /// Banner-tap entry point that shows the in-app system mic prompt
  /// when the OS still will, and deep-links to Settings on permanent
  /// denial. Returns the post-call granted state. Prefer this over
  /// jumping straight to [openSystemSettings] — on a fresh install
  /// the mic entry isn't even in the Privacy pane until the first
  /// request has been made.
  static Future<bool> requestAudioPermission() =>
      XCameraBackend.instance.requestAudioPermission();

  /// Opens camera privacy Settings on macOS and app Settings on mobile.
  /// Re-query authorization on foreground return.
  static Future<void> openSystemSettings() =>
      XCameraBackend.instance.openSettings();

  /// Texture-backed widget that renders the live preview at its parent's
  /// size. Hero-flightable.
  Widget buildPreview() => XCameraPreview(controller: this);

  int _requireHandle(String op) {
    _throwIfDisposed(op);
    final h = _handle;
    if (h == null) {
      throw const XCameraException('not_initialized');
    }
    return h;
  }

  void _throwIfDisposed(String op) {
    if (_disposed) {
      throw XCameraException('disposed', '$op called on a disposed controller');
    }
  }
}
