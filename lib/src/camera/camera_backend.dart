import 'dart:async';

import 'package:flutter/services.dart';

import 'package:ux/src/file.dart' show XFile;
import 'package:ux/src/camera/camera.dart' show XCameraDescription, XFlashMode, XResolutionPreset;
import 'package:ux/src/camera/camera_channel.dart' show MethodChannelXCameraBackend;

/// Backend contract that [XCameraController] dispatches into. The default
/// implementation calls into native code via the `ux/camera` /
/// `ux/camera/events` channels; tests substitute their own (see
/// `package:ux/testing.dart`'s `FakeXCameraBackend`).
///
/// Every per-instance call carries a `handle` returned by [create] so
/// the plugin can route to the right native session. Multiple
/// controllers can hold simultaneous handles.
abstract class XCameraBackend {
  /// Swap to inject a fake before any UI code mounts a controller.
  static XCameraBackend instance = MethodChannelXCameraBackend();

  /// Enumerate camera devices. The result is stable for the lifetime
  /// of the process.
  Future<List<XCameraDescription>> availableCameras();

  /// Allocate a native camera instance bound to [cameraId]. Returns the
  /// handle (for subsequent calls), the FlutterTexture id (for the
  /// preview widget), and the sensor-natural-orientation preview size.
  ///
  /// Throws [XCameraException("device_busy")] if another instance
  /// already holds the device, or [XCameraException("audio_busy")]
  /// when [enableAudio] is true and another instance holds the
  /// app-global audio session.
  Future<XCameraCreateResult> create({
    required String cameraId,
    required bool enableAudio,
    required XResolutionPreset preset,
  });

  /// Start the session. Native side resolves camera + audio permissions
  /// before the future completes. Throws
  /// [XCameraException("permission_denied")] on denial.
  Future<void> initialize(int handle);

  /// Tear down the session. Cancels any in-flight recording, releases
  /// the camera device and the audio claim. Safe to call repeatedly;
  /// no-op once disposed.
  Future<void> disposeInstance(int handle);

  /// Swap to a different camera mid-session. Resets the lock and clears
  /// any pending recording. Returns the new preview size and rotation;
  /// the size may again be `Size.zero` initially on Android, with a
  /// follow-up [XCameraPreviewSizeChanged] event.
  Future<({Size previewSize, int previewRotationQuarterTurns})> setDescription(
    int handle,
    String cameraId,
  );

  /// Set the flash mode used for the next [takePicture]. On front cameras
  /// without a screen-flash fallback the backend silently no-ops; the
  /// caller is responsible for not offering flash UI there.
  Future<void> setFlashMode(int handle, XFlashMode mode);

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
  Future<XFile> takePicture(int handle, DeviceOrientation snapshotOrientation);

  /// Begin recording video. [snapshotOrientation] is baked into the
  /// writer track's transform — the file plays back rotated even if
  /// the device returns to portrait mid-recording.
  Future<void> startVideoRecording(
    int handle,
    DeviceOrientation snapshotOrientation,
  );

  /// Stop recording and return the resulting MP4 on disk.
  Future<XFile> stopVideoRecording(int handle);

  /// Live event stream for [handle]: device-orientation changes,
  /// session errors, interrupted/resumed lifecycle pings. The
  /// controller subscribes during [initialize] and unsubscribes on
  /// [disposeInstance].
  Stream<XCameraEvent> events(int handle);

  /// Reads camera authorization without a session, prompt or microphone access.
  Future<bool> cameraPermissionGranted();

  /// Requests camera access or opens Settings if another prompt is unavailable.
  /// Returns current authorization; Settings changes require a foreground query.
  Future<bool> requestCameraPermission();

  /// True iff the user has granted microphone access. Cheap; safe to
  /// re-poll on app foregrounding to detect grants made via Settings.
  Future<bool> audioPermissionGranted();

  /// Attempt to grant mic access. Shows the in-app system prompt when
  /// the OS is willing to surface one (fresh install, or a first
  /// denial that's still retryable on Android); on permanent denial,
  /// deep-links into Settings and resolves to `false`. Returns the
  /// post-call granted state. Avoids the fresh-install trap where the
  /// mic entry isn't in the Privacy pane until [requestAccess] has
  /// fired at least once.
  Future<bool> requestAudioPermission();

  /// Opens camera privacy Settings on macOS and app Settings on mobile.
  /// Authorization changes require a foreground query.
  Future<void> openSettings();
}

/// The tuple returned by [XCameraBackend.create] — everything the
/// controller needs to start serving the preview widget and routing
/// subsequent calls.
class XCameraCreateResult {
  /// Binds the native session handle to the preview it serves.
  const XCameraCreateResult({
    required this.handle,
    required this.textureId,
    required this.previewSize,
    this.previewRotationQuarterTurns = 0,
  });

  /// Identifies the native session in every subsequent call.
  final int handle;

  /// Texture the preview widget renders.
  final int textureId;

  /// Initial preview size; may be `Size.zero` when the native side
  /// can't determine it synchronously (Android CameraX needs the
  /// first `SurfaceRequest` to fire before it knows). In that case
  /// a [XCameraPreviewSizeChanged] event follows.
  final Size previewSize;

  /// Number of 90° CW rotations the Texture widget needs. iOS: 0.
  /// Android: derived from the selected camera's sensor orientation.
  final int previewRotationQuarterTurns;
}

/// Events pushed by the native side over `ux/camera/events`. Sealed —
/// new variants land here as the contract grows.
sealed class XCameraEvent {
  /// Tags the event with the session it came from.
  const XCameraEvent(this.handle);

  /// The session that emitted this event.
  final int handle;
}

/// Fired when the device's physical orientation changes.
class XCameraDeviceOrientationChanged extends XCameraEvent {
  /// Carries the orientation the device has moved to.
  const XCameraDeviceOrientationChanged(super.handle, this.orientation);

  /// How the device is now held.
  final DeviceOrientation orientation;
}

/// Fired when the native session fails.
class XCameraSessionError extends XCameraEvent {
  /// Carries the failure's code and message.
  const XCameraSessionError(super.handle, this.code, this.description);

  /// Stable identifier of the failure.
  final String code;

  /// Human-readable detail, where the native side supplied one.
  final String? description;
}

/// Fired when the OS takes the camera away — a call, another app, or a
/// system alert.
class XCameraSessionInterrupted extends XCameraEvent {
  /// Carries why the session was interrupted.
  const XCameraSessionInterrupted(super.handle, this.reason);

  /// What the OS gave as the cause.
  final String reason;
}

/// Fired when the session gets the camera back after an interruption.
class XCameraSessionResumed extends XCameraEvent {
  /// Marks the session as running again.
  const XCameraSessionResumed(super.handle);
}

/// Fired when the native side learns or revises the preview's pixel
/// dimensions. Android emits this after CameraX's first
/// `SurfaceRequest` resolves (the size isn't known at `create` time);
/// iOS doesn't emit it (the size lands in the `create` result
/// synchronously from `device.activeFormat`).
class XCameraPreviewSizeChanged extends XCameraEvent {
  /// Carries the preview's revised pixel dimensions.
  const XCameraPreviewSizeChanged(super.handle, this.previewSize);

  /// Preview dimensions in the sensor's natural orientation.
  final Size previewSize;
}

/// Free-text diagnostic message from the native recorder. Routed by
/// the controller to `Log.tag('camera').i(...)` so it lands in the
/// log_server pipeline (`~/banlu/tools/log_server/data/banlu.jsonl`).
class XCameraDiagnostic extends XCameraEvent {
  /// Carries the recorder's message.
  const XCameraDiagnostic(super.handle, this.message);

  /// What the native recorder reported.
  final String message;
}
