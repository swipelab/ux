/// Flutter toolkit for fluid, native-feeling UIs.
///
/// Includes [UxKeyboard] for frame-accurate keyboard height tracking,
/// [BendBox] for curved layout painting, and bezier curve utilities.
library;

export 'src/app_info.dart';
export 'src/bend_box.dart';
export 'src/json_extension.dart';
export 'src/bezier.dart';
export 'src/camera/camera.dart';
export 'src/camera/camera_backend.dart' show UxCameraBackend, UxCameraCreateResult, UxCameraEvent, UxCameraDeviceOrientationChanged, UxCameraSessionError, UxCameraSessionInterrupted, UxCameraSessionResumed, UxCameraDiagnostic;
export 'src/camera/camera_channel.dart' show MethodChannelUxCameraBackend;
export 'src/camera/camera_preview.dart';
export 'src/clipboard.dart';
export 'src/file.dart';
export 'src/gallery.dart';
export 'src/keyboard.dart';
export 'src/auto_map.dart';
export 'src/scanner.dart';
export 'src/sensor.dart';
export 'src/functional.dart';
export 'src/crash.dart';
export 'src/log.dart';
export 'src/log_http.dart';