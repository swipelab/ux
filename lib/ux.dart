/// Flutter toolkit for fluid, native-feeling UIs.
///
/// Includes [XKeyboard] for frame-accurate keyboard height tracking,
/// [BendBox] for curved layout painting, bezier curve utilities,
/// reactive primitives ([Emitter], [ValueEmitter]), a custom navigation
/// system ([XApp], [XRouter], [Screen]), and modal sheets ([Sheet]).
library;

export 'src/app_group.dart';
export 'src/app_info.dart';
export 'src/bend_box.dart';
export 'src/json_extension.dart';
export 'src/bezier.dart';
export 'src/audio/x_audio_capture.dart';
export 'src/audio/x_audio_sink.dart';
export 'src/camera/camera.dart';
export 'src/camera/camera_backend.dart' show XCameraBackend, XCameraCreateResult, XCameraEvent, XCameraDeviceOrientationChanged, XCameraSessionError, XCameraSessionInterrupted, XCameraSessionResumed, XCameraDiagnostic, XCameraPreviewSizeChanged;
export 'src/camera/camera_channel.dart' show MethodChannelXCameraBackend;
export 'src/camera/camera_preview.dart';
export 'src/video/ffmpeg_license.dart' show registerFfmpegLicense;
export 'src/video/x_video_exporter.dart';
export 'src/video/x_video_player.dart';
export 'src/video/x_video_player_backend.dart' show XVideoPlayerBackend, XVideoPlayerCreateResult, XVideoPlayerMetadata, XVideoPlayerEvent, XVideoPlayerStateChanged, XVideoPlayerSizeChanged, XVideoPlayerCompleted, XVideoPlayerError;
export 'src/video/x_video_player_channel.dart' show MethodChannelXVideoPlayerBackend;
export 'src/video/x_video_player_view.dart' show XVideoPlayerView;
export 'src/image/x_image_probe.dart';
export 'src/video/x_video_probe.dart';
export 'src/clipboard.dart';
export 'src/crypto.dart';
export 'src/notifications/x_notifications.dart';
export 'src/window/x_window.dart';
export 'src/drop/x_drop.dart' show XDrop, XDropFile, XDropRegion, ZipJob;
export 'src/file.dart';
export 'src/gallery.dart';
export 'src/keyboard.dart';
export 'src/view_padding.dart';
export 'src/auto_map.dart';
export 'src/scanner.dart';
export 'src/shortcuts.dart';
export 'src/url.dart';
export 'src/sensor.dart';
export 'src/functional.dart';
export 'src/crash.dart';
export 'src/log.dart';
export 'src/log_http.dart';

// Reactive primitives, lifecycle, DI, async tasks (formerly `stated`).
export 'src/core/core.dart';

// Reactive state base + builders.
export 'src/reactive/reactive.dart';
export 'src/reactive/reactive_builder.dart';
export 'src/reactive/future_reactive_builder.dart';

// Navigation (Screen, XApp, XRouter, ScreenStack, ScreenHero, …).
export 'src/navi/screen.dart';
export 'src/navi/screen_host.dart';
export 'src/navi/screen_stack.dart';
export 'src/navi/hero.dart';
export 'src/navi/sheet_screen.dart';
export 'src/navi/transitions.dart';
export 'src/navi/router.dart';

// Animations, layout, sheet, pane.
export 'src/anim/animated_color.dart';
export 'src/anim/animated_double.dart';
export 'src/anim/dock.dart';
export 'src/anim/measured.dart';
export 'src/anim/pane.dart';
export 'src/anim/sheet.dart';
