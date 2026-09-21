import 'dart:io' as io;
import 'dart:math' as math;

import 'package:ux/src/media/timing.dart';

import 'package:flutter/foundation.dart';
import 'package:ux/gallery.dart';
import 'package:ux/src/media/camera/camera_session.dart';
import 'package:ux/src/media/camera/camera_cell.dart';
import 'package:ux/src/media/camera/camera_flight.dart';

import 'package:ux/src/media/camera/camera_capture.dart';
import 'package:ux/src/media/design.dart';
import 'package:ux/src/media/camera/camera_button.dart';
import 'package:ux/src/media/camera/camera_guideline.dart';
import 'package:ux/src/media/camera/camera_thumb.dart';
import 'package:ux/src/media/camera/flash_button.dart';
import 'package:ux/src/media/camera/photo_video_swap.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ux/src/media/host.dart';
import 'package:ux/src/media/mic_permission_banner.dart';
import 'package:ux/src/media/touch.dart';
import 'package:ux/src/media/x_media.dart';
import 'package:ux/ux.dart';
import 'package:ux/camera.dart';
import 'package:ux/log.dart';
import 'package:ux/sensor.dart';

/// The camera: takes a photo or records a video, and pops with it as an
/// [XMedia], or with nothing when closed.
class CameraPage with Screen<XMedia?>, Emitter {
  /// Borrows [session] when supplied; otherwise owns a new session.
  CameraPage({CameraSession? session, this.filter, this.cellSource})
    : session = session ?? CameraSession(),
      _ownsSession = session == null,
      _photo = filter != XAssetKind.video;

  /// A supplied session remains owned by the caller after this page closes.
  final CameraSession session;
  final bool _ownsSession;

  /// The picker cell lending its live preview through the route transition.
  final CameraCellSource? cellSource;
  Rect? _cellRect;
  final _previewSlot = GlobalKey();
  CurvedAnimation? _flightAnimation;

  /// Restricts capture to this kind; null permits photos and videos.
  final XAssetKind? filter;

  /// The shared owner's current controller, absent during replacement.
  ValueListenable<XCameraController?> get controller => session;

  /// The devices discovered by the shared owner.
  List<XCameraDescription> get cameras => session.cameras;

  /// The failure shown in place of the preview.
  String? error;
  bool _photo;

  /// Whether the shutter captures a still, subject to [filter].
  bool get photo => _photo;

  /// Whether the shared controller has an active recording.
  bool get recording => session.value?.value.isRecordingVideo ?? false;

  /// Whether still captures from the back camera fire the flash.
  bool flashOn = false;

  /// Physical orientation for the control icons.
  DeviceOrientation orientation = DeviceOrientation.portraitUp;

  /// Microphone authorization, refreshed on foreground return.
  bool micPermissionGranted = true;
  bool _capturing = false;
  Future<void>? _cancellation;
  bool get _closed => disposed || popped;

  late final VoidCallback _orientationListener = _onOrientationChanged;
  late final VoidCallback _lifecycleListener = _onLifecycle;
  late final VoidCallback _sessionListener = _safeNotify;
  ValueListenable<AppLifecycleState>? _lifecycle;
  AppLifecycleState _lastLifecycle = AppLifecycleState.resumed;

  @override
  Duration get transitionDuration => kMediaFlightDuration;

  @override
  Widget buildTransition(
    BuildContext context,
    Animation<double> animation,
    Widget child,
  ) {
    final source = _cellRect;
    if (source == null) {
      return ScreenTransitions.responsive(context, animation, child);
    }
    // Navigator measures an incoming route offstage before its first visible frame.
    if (ModalRoute.of(context)?.offstage != true) cellSource!.cover();
    final flight = _flightAnimation ??= CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeOutCubic.flipped,
    );
    final t = flight.value;
    return ListenableBuilder(
      listenable: this,
      builder: (context, _) {
        if (error != null) return Opacity(opacity: t, child: child);
        return CameraFlight(
          source: cellSource?.rect ?? source,
          target: _previewSlot,
          progress: t,
          onDetach: cellSource!.uncover,
          background: _buildFrame(
            context,
            const SizedBox.expand(),
            background: true,
          ),
          chrome: child,
          preview: IgnorePointer(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8 * (1 - t)),
              child: CameraThumb(
                controller: controller,
                child: Stack(
                  children: [
                    Opacity(
                      opacity: t,
                      child: CustomPaint(
                        painter: CameraGuidelinePainter(),
                        child: const SizedBox.expand(),
                      ),
                    ),
                    Opacity(opacity: 1 - t, child: const CameraCellIcon()),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Iterable<DeviceOrientation> get supportedOrientations => const [
    DeviceOrientation.portraitUp,
  ];

  @override
  void onPush() {
    super.onPush();
    _cellRect = cellSource?.rect;
    session.addListener(_sessionListener);
    _initCamera();
    if (filter != XAssetKind.image) _refreshMicPermission();
  }

  Future<void> _refreshMicPermission() async {
    try {
      final granted = await XCameraController.audioPermissionGranted();
      if (_closed || granted == micPermissionGranted) return;
      micPermissionGranted = granted;
      _safeNotify();
    } catch (error, stack) {
      Log.tag('camera')
          .w('microphone status failed', error: error, stackTrace: stack);
    }
  }

  @override
  void onActive() {
    super.onActive();
    orientation = XSensor.orientationListenable.value;
    XSensor.orientationListenable.addListener(_orientationListener);
    _lifecycle = MediaHost.current.lifecycle;
    _lastLifecycle = _lifecycle!.value;
    _lifecycle!.addListener(_lifecycleListener);
  }

  void _removeActiveListeners() {
    _lifecycle?.removeListener(_lifecycleListener);
    _lifecycle = null;
    XSensor.orientationListenable.removeListener(_orientationListener);
  }

  @override
  void onInactive() {
    _removeActiveListeners();
    super.onInactive();
  }

  void _onOrientationChanged() {
    final next = XSensor.orientationListenable.value;
    if (next != orientation) {
      orientation = next;
      _safeNotify();
    }
  }

  void _onLifecycle() {
    final next = _lifecycle!.value;
    final wasPaused = _lastLifecycle != AppLifecycleState.resumed;
    _lastLifecycle = next;
    if (next == AppLifecycleState.resumed &&
        wasPaused &&
        filter != XAssetKind.image) {
      _refreshMicPermission();
      _refreshControllerAudioPermission();
    }
  }

  Future<void> _refreshControllerAudioPermission() async {
    try {
      await session.useController(
        (controller) => controller.refreshAudioPermission(),
      );
    } catch (error, stack) {
      Log.tag('camera').w(
        'controller microphone status failed',
        error: error,
        stackTrace: stack,
      );
    }
  }

  void _safeNotify() {
    if (!_closed) notifyListeners();
  }

  void _captureError(Object failure, StackTrace stack) {
    Log.tag('camera')
        .e('camera operation failed', error: failure, stackTrace: stack);
    if (_closed) return;
    error = failure is XCameraException
        ? failure.description ?? strings.cameraError
        : strings.cameraError;
    _safeNotify();
  }

  Future<void> _initCamera() async {
    try {
      final controller = await session.initialize();
      if (_closed) return;
      if (controller == null) {
        error = cameras.isEmpty
            ? strings.noCameraFound
            : strings.failedToAccessCamera;
      }
      _safeNotify();
    } catch (error, stack) {
      _captureError(error, stack);
    }
  }

  /// Changes lens through the shared owner when capture is idle.
  Future<void> flipCamera() async {
    if (_closed || _capturing || recording) return;
    try {
      await session.flipCamera();
    } catch (error, stack) {
      _captureError(error, stack);
    }
  }

  /// Toggles flash for still captures.
  void toggleFlash() {
    flashOn = !flashOn;
    _safeNotify();
  }

  /// Selects an allowed mode while capture is idle.
  void setPhoto(bool isPhoto) {
    if (_closed || _capturing || recording || photo == isPhoto) return;
    if (isPhoto ? filter == XAssetKind.video : filter == XAssetKind.image) {
      return;
    }
    _photo = isPhoto;
    _safeNotify();
  }

  /// Captures a still, or starts/stops recording in video mode.
  Future<void> takePhoto() async {
    if (_closed || _capturing) return;
    if (!photo) {
      await endVideo();
      return;
    }
    if (recording) return;
    _capturing = true;
    _safeNotify();
    try {
      final capture = await session.useController((controller) async {
        final physical = XSensor.orientation;
        final sensor = controller.description.sensorOrientation;
        final isFront = controller.description.lens == XCameraLens.front;
        await controller.setFlashMode(
          flashOn && !isFront ? XFlashMode.always : XFlashMode.off,
        );
        final file = await controller.takePicture();
        return (
          file: file,
          physical: physical,
          sensorOrientation: sensor,
          isFrontCamera: isFront,
        );
      });
      if (capture == null) return;
      final normalized = await normalizeCameraCapture(
        io.File(capture.file.path),
        physical: capture.physical,
        sensorOrientation: capture.sensorOrientation,
        isFrontCamera: capture.isFrontCamera,
      );
      if (!_closed) pop(ImageMedia(file: normalized));
    } catch (error, stack) {
      _captureError(error, stack);
    } finally {
      _capturing = false;
      _safeNotify();
    }
  }

  /// Starts an allowed video capture, with sound when available.
  Future<void> takeVideo() async {
    if (_closed || _capturing || recording || filter == XAssetKind.image) {
      return;
    }
    _capturing = true;
    _photo = false;
    _safeNotify();
    try {
      final controller = await ensureAudio();
      if (_closed || controller == null) return;
      await session.useController(
        (controller) => controller.startVideoRecording(),
      );
    } catch (error, stack) {
      _captureError(error, stack);
    } finally {
      _capturing = false;
      _safeNotify();
    }
  }

  /// Returns the recording, or starts one if capture is idle.
  Future<void> endVideo() async {
    if (_closed || _capturing || filter == XAssetKind.image) return;
    if (!recording) {
      await takeVideo();
      return;
    }
    _capturing = true;
    _safeNotify();
    try {
      final file = await session.useController(
        (controller) => controller.stopVideoRecording(),
      );
      if (!_closed && file != null) pop(VideoMedia(file: io.File(file.path)));
    } catch (error, stack) {
      _captureError(error, stack);
    } finally {
      _capturing = false;
      _photo = filter != XAssetKind.video;
      _safeNotify();
    }
  }

  /// Reopens the shared owner's controller for audio when necessary.
  Future<XCameraController?> ensureAudio() => session.ensureAudio();

  Future<void> _cancelRecording() => _cancellation ??= session
      .stopRecording()
      .catchError((Object error, StackTrace stack) {
        Log.tag('camera')
            .w('cancel recording failed', error: error, stackTrace: stack);
      });

  @override
  void onDetach() {
    _cancelRecording();
    super.onDetach();
  }

  Widget _buildMicPermissionHint() {
    final spacer = SizedBox(height: 8);
    final show = !photo && !recording && !micPermissionGranted;
    if (!show) return spacer;
    return Padding(
      padding: EdgeInsets.only(bottom: space.sm),
      child: MicPermissionBanner(
        label: strings.cameraTapToEnableMic,
        onTap: () async {
          await XCameraController.requestAudioPermission();
          await _refreshMicPermission();
        },
      ),
    );
  }

  /// What the shutter shows for [photo] and [recording].
  CameraButtonState get cameraButtonState => photo
      ? CameraButtonState.photo
      : (recording ? CameraButtonState.recording : CameraButtonState.video);

  @override
  void onRemoved() {
    cellSource?.uncover();
    super.onRemoved();
  }

  @override
  void dispose() {
    _flightAnimation?.dispose();
    _removeActiveListeners();
    session.removeListener(_sessionListener);
    if (_ownsSession) {
      session.dispose();
    } else {
      _cancelRecording();
    }
    super.dispose();
  }

  @override
  Widget buildPresenter(BuildContext context) => _buildFrame(
    context,
    _buildContent(context),
    background: _cellRect == null || error != null,
  );

  Widget _buildFrame(
    BuildContext context,
    Widget content, {
    required bool background,
  }) {
    if (!MediaHost.current.isWideScreen(context)) {
      return Scaffold(
        backgroundColor: background
            ? const Color(0xFF000000)
            : Colors.transparent,
        body: content,
      );
    }
    return GestureDetector(
      onTap: pop,
      child: Container(
        color: background ? colors.scrim : null,
        child: Center(
          child: GestureDetector(
            onTap: () {},
            child: Card(
              color: background ? const Color(0xFF000000) : Colors.transparent,
              elevation: background ? null : 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 540),
                child: content,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    if (error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icons.videoOff, size: 44, color: colors.mediaHint),
            SizedBox(height: 12),
            Text(error!, style: text.body.copyWith(color: colors.mediaHint)),
            SizedBox(height: 16),
            TextButton(onPressed: pop, child: Text(strings.close)),
          ],
        ),
      );
    }

    // Mobile screens want a portrait composer (3:4 = camera-app
    // convention). Desktop cameras are physically landscape and the
    // native side reports landscape preview dims, so flip the
    // AspectRatio to 4:3 there — the Card constraint at maxWidth: 540
    // still keeps the dialog tidy.
    final cameraAspect = MediaHost.current.isWideScreen(context)
        ? 4 / 3
        : 3 / 4;

    return Stack(
      children: [
        SafeArea(
          child: Center(
            child: AspectRatio(
              aspectRatio: cameraAspect,
              child: _cellRect != null
                  ? SizedBox.expand(key: _previewSlot)
                  : CustomPaint(
                      foregroundPainter: CameraGuidelinePainter(),
                      child: CameraThumb(controller: controller),
                    ),
            ),
          ),
        ),
        if (filter != XAssetKind.video)
          Dock.topLeft(
            child: ListenableBuilder(
              listenable: insets,
              builder: (context, child) => Padding(
                padding: EdgeInsets.only(
                  left: 24,
                  top: math.max(48, insets.viewPadding.top),
                ),
                child: child,
              ),
              child: _Rotating(
                orientation: orientation,
                child: FlashButton(onPress: toggleFlash, on: flashOn),
              ),
            ),
          ),
        Dock.bottom(
          bottom: 56,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildMicPermissionHint(),
              if (filter == null)
                Opacity(
                  opacity: recording ? 0 : 1,
                  child: PhotoVideoSwap(
                    isPhoto: photo,
                    onChanged: recording ? (_) {} : setPhoto,
                  ),
                ),
              const SizedBox(height: 6),
              Row(
                children: [
                  const SizedBox(width: 24),
                  _Rotating(
                    orientation: orientation,
                    child: _CircleButton(
                      onPress: pop,
                      child: const Icon(CupertinoIcons.xmark),
                    ),
                  ),
                  Expanded(
                    child: Center(
                      child: CameraButton(
                        value: cameraButtonState,
                        onPress: _capturing ? null : takePhoto,
                        onLongPress:
                            _capturing ||
                                recording ||
                                filter == XAssetKind.image
                            ? null
                            : takeVideo,
                      ),
                    ),
                  ),
                  _Rotating(
                    orientation: orientation,
                    child: Opacity(
                      opacity: recording ? 0 : 1,
                      child: _CircleButton(
                        onPress: _capturing || recording ? null : flipCamera,
                        child: const Icon(CupertinoIcons.arrow_2_circlepath),
                      ),
                    ),
                  ),
                  const SizedBox(width: 24),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({required this.onPress, required this.child});

  final VoidCallback? onPress;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Touch(
      onPress: onPress,
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: colors.onMedia.withValues(alpha: .15),
        ),
        padding: const EdgeInsets.all(12),
        child: IconTheme(
          data: IconThemeData(color: colors.onMedia),
          child: child,
        ),
      ),
    );
  }
}

class _Rotating extends StatelessWidget {
  const _Rotating({required this.orientation, required this.child});

  final DeviceOrientation orientation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedRotation(
      duration: kAnimation,
      curve: Curves.easeOutCubic,
      turns: _turnsFor(orientation),
      child: child,
    );
  }

  static double _turnsFor(DeviceOrientation o) => switch (o) {
    DeviceOrientation.portraitUp => 0,
    DeviceOrientation.landscapeLeft => 0.25,
    DeviceOrientation.portraitDown => 0.5,
    DeviceOrientation.landscapeRight => -0.25,
  };
}
