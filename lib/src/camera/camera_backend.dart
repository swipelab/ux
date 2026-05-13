import 'dart:async';

import 'package:flutter/services.dart';

import '../file.dart' show UxFile;
import 'camera.dart' show UxCameraDescription, UxFlashMode, UxResolutionPreset;
import 'camera_channel.dart' show MethodChannelUxCameraBackend;

/// Backend contract that [UxCameraController] dispatches into. The default
/// implementation calls into native code via the `ux/camera` /
/// `ux/camera/events` channels; tests substitute their own (see
/// `package:ux/testing.dart`'s `FakeUxCameraBackend`).
///
/// Every per-instance call carries a `handle` returned by [create] so
/// the plugin can route to the right native session. Multiple
/// controllers can hold simultaneous handles.
abstract class UxCameraBackend {
  /// Swap to inject a fake before any UI code mounts a controller.
  static UxCameraBackend instance = MethodChannelUxCameraBackend();

  /// Enumerate camera devices. The result is stable for the lifetime
  /// of the process.
  Future<List<UxCameraDescription>> availableCameras();

  /// Allocate a native camera instance bound to [cameraId]. Returns the
  /// handle (for subsequent calls), the FlutterTexture id (for the
  /// preview widget), and the sensor-natural-orientation preview size.
  ///
  /// Throws [UxCameraException("device_busy")] if another instance
  /// already holds the device, or [UxCameraException("audio_busy")]
  /// when [enableAudio] is true and another instance holds the
  /// app-global audio session.
  Future<UxCameraCreateResult> create({
    required String cameraId,
    required bool enableAudio,
    required UxResolutionPreset preset,
  });

  /// Start the session. Native side resolves camera + audio permissions
  /// before the future completes. Throws
  /// [UxCameraException("permission_denied")] on denial.
  Future<void> initialize(int handle);

  /// Tear down the session. Cancels any in-flight recording, releases
  /// the camera device and the audio claim. Safe to call repeatedly;
  /// no-op once disposed.
  Future<void> disposeInstance(int handle);

  /// Swap to a different camera mid-session. Resets the lock and clears
  /// any pending recording. Returns the new preview size and rotation;
  /// the size may again be `Size.zero` initially on Android, with a
  /// follow-up [UxCameraPreviewSizeChanged] event.
  Future<({Size previewSize, int previewRotationQuarterTurns})> setDescription(
    int handle,
    String cameraId,
  );

  /// Set the flash mode used for the next [takePicture]. On front cameras
  /// without a screen-flash fallback the backend silently no-ops; the
  /// caller is responsible for not offering flash UI there.
  Future<void> setFlashMode(int handle, UxFlashMode mode);

  /// Pin the preview's connection orientation. Used today only to lock
  /// the preview to portrait so it never appears stretched/rotated.
  Future<void> lockCaptureOrientation(int handle, DeviceOrientation orientation);

  /// Release the orientation lock — the preview falls back to following
  /// physical device orientation. Unused by the chat composer; kept for
  /// API symmetry.
  Future<void> unlockCaptureOrientation(int handle);

  /// Take a still photo. [snapshotOrientation] is applied to the photo
  /// connection just before capture so the file's EXIF orientation
  /// matches how the user was holding the device.
  Future<UxFile> takePicture(int handle, DeviceOrientation snapshotOrientation);

  /// Begin recording video. [snapshotOrientation] is baked into the
  /// writer track's transform — the file plays back rotated even if
  /// the device returns to portrait mid-recording.
  Future<void> startVideoRecording(
    int handle,
    DeviceOrientation snapshotOrientation,
  );

  /// Stop recording and return the resulting MP4 on disk.
  Future<UxFile> stopVideoRecording(int handle);

  /// Live event stream for [handle]: device-orientation changes,
  /// session errors, interrupted/resumed lifecycle pings. The
  /// controller subscribes during [initialize] and unsubscribes on
  /// [disposeInstance].
  Stream<UxCameraEvent> events(int handle);

  /// True iff the user has granted microphone access. Cheap; safe to
  /// re-poll on app foregrounding to detect grants made via Settings.
  Future<bool> audioPermissionGranted();

  /// Deep-link into the system Settings page for this app. Caller is
  /// expected to refresh [audioPermissionGranted] on
  /// `AppLifecycleState.resumed`.
  Future<void> openSettings();
}

/// The tuple returned by [UxCameraBackend.create] — everything the
/// controller needs to start serving the preview widget and routing
/// subsequent calls.
class UxCameraCreateResult {
  const UxCameraCreateResult({
    required this.handle,
    required this.textureId,
    required this.previewSize,
    this.previewRotationQuarterTurns = 0,
  });

  final int handle;
  final int textureId;

  /// Initial preview size; may be `Size.zero` when the native side
  /// can't determine it synchronously (Android CameraX needs the
  /// first `SurfaceRequest` to fire before it knows). In that case
  /// a [UxCameraPreviewSizeChanged] event follows.
  final Size previewSize;

  /// Number of 90° CW rotations the Texture widget needs. iOS: 0.
  /// Android: derived from the selected camera's sensor orientation.
  final int previewRotationQuarterTurns;
}

/// Events pushed by the native side over `ux/camera/events`. Sealed —
/// new variants land here as the contract grows.
sealed class UxCameraEvent {
  const UxCameraEvent(this.handle);
  final int handle;
}

class UxCameraDeviceOrientationChanged extends UxCameraEvent {
  const UxCameraDeviceOrientationChanged(super.handle, this.orientation);
  final DeviceOrientation orientation;
}

class UxCameraSessionError extends UxCameraEvent {
  const UxCameraSessionError(super.handle, this.code, this.description);
  final String code;
  final String? description;
}

class UxCameraSessionInterrupted extends UxCameraEvent {
  const UxCameraSessionInterrupted(super.handle, this.reason);
  final String reason;
}

class UxCameraSessionResumed extends UxCameraEvent {
  const UxCameraSessionResumed(super.handle);
}

/// Fired when the native side learns or revises the preview's pixel
/// dimensions. Android emits this after CameraX's first
/// `SurfaceRequest` resolves (the size isn't known at `create` time);
/// iOS doesn't emit it (the size lands in the `create` result
/// synchronously from `device.activeFormat`).
class UxCameraPreviewSizeChanged extends UxCameraEvent {
  const UxCameraPreviewSizeChanged(super.handle, this.previewSize);
  final Size previewSize;
}

/// Free-text diagnostic message from the native recorder. Routed by
/// the controller to `Log.tag('camera').i(...)` so it lands in the
/// log_server pipeline (`~/banlu/tools/log_server/data/banlu.jsonl`).
class UxCameraDiagnostic extends UxCameraEvent {
  const UxCameraDiagnostic(super.handle, this.message);
  final String message;
}
