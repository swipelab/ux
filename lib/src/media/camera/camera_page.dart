import 'dart:io' as io;

import 'package:ux/src/media/camera/camera_capture.dart';
import 'package:ux/src/media/design.dart';
import 'package:ux/src/media/camera/camera_button.dart';
import 'package:ux/src/media/camera/camera_guideline.dart';
import 'package:ux/src/media/camera/camera_thumb.dart';
import 'package:ux/src/media/camera/flash_button.dart';
import 'package:ux/src/media/camera/photo_video_swap.dart';
import 'package:collection/collection.dart';
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
  /// The open camera; absent while one is being opened.
  final ValueEmitter<XCameraController?> controller = ValueEmitter(null);
  /// The device's cameras.
  List<XCameraDescription> cameras = const [];
  /// What went wrong, shown in place of the preview.
  String? error;
  /// Whether the shutter takes a photo rather than a video.
  bool photo = true;
  /// Whether a video is being recorded.
  bool recording = false;
  /// Whether a photo from a back camera fires the flash.
  bool flashOn = false;
  /// The device's physical orientation.
  DeviceOrientation orientation = DeviceOrientation.portraitUp;

  late final VoidCallback _orientationListener = _onOrientationChanged;
  late final VoidCallback _lifecycleListener = _onLifecycle;
  AppLifecycleState _lastLifecycle = AppLifecycleState.resumed;

  /// Mic permission as reported by the OS. Polled on push + on every
  /// foreground transition so a grant made via Settings is reflected
  /// without restarting the page. Defaults to true so the banner
  /// doesn't flicker on first paint before the first poll lands.
  bool micPermissionGranted = true;

  @override
  Widget buildTransition(BuildContext context, Animation<double> animation, Widget child) {
    return ScreenTransitions.responsive(context, animation, child);
  }

  @override
  Iterable<DeviceOrientation> get supportedOrientations =>
      const [DeviceOrientation.portraitUp];

  @override
  void onPush() {
    super.onPush();
    _initCamera();
    _refreshMicPermission();
  }

  Future<void> _refreshMicPermission() async {
    try {
      final granted = await XCameraController.audioPermissionGranted();
      if (granted == micPermissionGranted) return;
      micPermissionGranted = granted;
      _safeNotify();
    } catch (_) {
      // Mic-permission query is best-effort. A failure shouldn't
      // disrupt the camera page — the banner stays hidden.
    }
  }

  @override
  void onActive() {
    super.onActive();
    orientation = XSensor.orientationListenable.value;
    XSensor.orientationListenable.addListener(_orientationListener);
    _lastLifecycle = MediaHost.current.lifecycle.value;
    MediaHost.current.lifecycle.addListener(_lifecycleListener);
  }

  @override
  void onInactive() {
    MediaHost.current.lifecycle.removeListener(_lifecycleListener);
    XSensor.orientationListenable.removeListener(_orientationListener);
    super.onInactive();
  }

  void _onOrientationChanged() {
    final next = XSensor.orientationListenable.value;
    if (next != orientation) {
      orientation = next;
      notifyListeners();
    }
  }

  void _onLifecycle() {
    final next = MediaHost.current.lifecycle.value;
    final wasPaused = _lastLifecycle != AppLifecycleState.resumed;
    _lastLifecycle = next;
    if (next == AppLifecycleState.resumed && wasPaused) {
      _refreshMicPermission();
      controller.value?.refreshAudioPermission();
    }
  }

  /// `notifyListeners()` after an `await` is a footgun — the page may
  /// have been popped while we were suspended, and the underlying
  /// Emitter throws an assertion in debug ("ChangeNotifier was used
  /// after being disposed") if we notify post-dispose. Every async
  /// path in this class uses this helper instead of the raw call.
  void _safeNotify() {
    if (disposed) return;
    notifyListeners();
  }

  Future<void> _initCamera() async {
    try {
      cameras = await uxAvailableCameras();
      if (cameras.isEmpty) {
        Log.tag('camera').w('no cameras available');
        error = strings.noCameraFound;
        notifyListeners();
        return;
      }
      final camera = cameras.firstWhere(
        (c) => c.lens == XCameraLens.front,
        orElse: () => cameras.first,
      );
      final ctrl = await _tryInitController(
        camera,
        XResolutionPreset.high,
        audio: false,
      );
      if (ctrl == null) {
        error = strings.failedToAccessCamera;
        notifyListeners();
        return;
      }
      controller.value = ctrl;
      notifyListeners();
    } on XCameraException catch (e, st) {
      Log.tag('camera').e('initCamera failed', error: e, stackTrace: st);
      error = e.description ?? strings.cameraError;
      notifyListeners();
    } catch (e, st) {
      Log.tag('camera').e('initCamera unexpected failure', error: e, stackTrace: st);
      error = strings.failedToAccessCamera;
      notifyListeners();
    }
  }

  /// Switches to a camera facing the other way, unless recording.
  Future<void> flipCamera() async {
    if (recording) return;
    final ctrl = controller.value;
    if (ctrl == null) return;
    final direction = ctrl.description.lens;
    final other = cameras.firstWhereOrNull((c) => c.lens != direction);
    if (other == null) return;
    await ctrl.setDescription(other);
    await ctrl.lockCaptureOrientation(DeviceOrientation.portraitUp);
    notifyListeners();
  }

  /// Turns the flash on or off.
  void toggleFlash() {
    flashOn = !flashOn;
    notifyListeners();
  }

  /// Chooses between photo and video.
  void setPhoto(bool isPhoto) {
    if (photo == isPhoto) return;
    photo = isPhoto;
    notifyListeners();
  }

  /// Takes a photo and pops with it.
  Future<void> takePhoto() async {
    final ctrl = controller.value;
    if (ctrl == null) return;
    if (!photo) {
      await endVideo();
      return;
    }
    if (recording) return;
    final physical = XSensor.orientation;
    final sensor = ctrl.description.sensorOrientation;
    final isFront = ctrl.description.lens == XCameraLens.front;
    try {
      await ctrl.setFlashMode(flashOn && !isFront ? XFlashMode.always : XFlashMode.off);
      final xFile = await ctrl.takePicture();
      final normalized = await normalizeCameraCapture(
        io.File(xFile.path),
        physical: physical,
        sensorOrientation: sensor,
        isFrontCamera: isFront,
      );
      pop(ImageMedia(file: normalized));
    } on XCameraException catch (e, st) {
      Log.tag('camera').e('takePhoto failed', error: e, stackTrace: st);
      error = e.description ?? strings.cameraError;
      notifyListeners();
    } catch (e, st) {
      Log.tag('camera').e('takePhoto unexpected failure', error: e, stackTrace: st);
      error = strings.cameraError;
      notifyListeners();
    }
  }

  /// Switches to video and starts recording, with sound when the microphone allows.
  Future<void> takeVideo() async {
    if (recording) return;
    photo = false;
    notifyListeners();
    final ctrl = await ensureAudio();
    if (ctrl == null) return;
    try {
      await ctrl.startVideoRecording();
      recording = true;
      notifyListeners();
    } on XCameraException catch (e, st) {
      Log.tag('camera').e('startVideoRecording failed', error: e, stackTrace: st);
      error = e.description ?? strings.cameraError;
      notifyListeners();
    } catch (e, st) {
      Log.tag('camera').e('startVideoRecording unexpected failure', error: e, stackTrace: st);
      error = strings.cameraError;
      notifyListeners();
    }
  }

  /// Stops recording and pops with the video.
  Future<void> endVideo() async {
    if (!recording) {
      await takeVideo();
      return;
    }
    final ctrl = controller.value;
    if (ctrl == null) return;
    try {
      final xFile = await ctrl.stopVideoRecording();
      recording = false;
      photo = true;
      notifyListeners();
      pop(VideoMedia(file: io.File(xFile.path)));
    } on XCameraException catch (e, st) {
      Log.tag('camera').e('stopVideoRecording failed', error: e, stackTrace: st);
      recording = false;
      photo = true;
      error = e.description ?? strings.cameraError;
      notifyListeners();
    } catch (e, st) {
      Log.tag('camera').e('stopVideoRecording unexpected failure', error: e, stackTrace: st);
      recording = false;
      photo = true;
      error = strings.cameraError;
      notifyListeners();
    }
  }

  /// The camera reopened with sound, or without it when that fails; absent when
  /// neither opens.
  Future<XCameraController?> ensureAudio() async {
    final current = controller.value;
    if (current == null) return null;
    if (current.enableAudio) return current;

    final description = current.description;
    final preset = current.resolutionPreset;

    controller.value = null;
    notifyListeners();
    await current.dispose();

    final next = await _tryInitController(description, preset, audio: true) ??
        await _tryInitController(description, preset, audio: false);
    controller.value = next;
    if (next == null) error = strings.cameraError;
    notifyListeners();
    return next;
  }

  Future<XCameraController?> _tryInitController(
    XCameraDescription description,
    XResolutionPreset preset, {
    required bool audio,
  }) async {
    final ctrl = XCameraController(description, preset, enableAudio: audio);
    try {
      await ctrl.initialize();
      await ctrl.lockCaptureOrientation(DeviceOrientation.portraitUp);
    } on XCameraException catch (e, st) {
      Log.tag('camera').w(
        '_tryInitController failed',
        fields: {'audio': audio, 'cameraId': description.id},
        error: e,
        stackTrace: st,
      );
      // initialize() already disposes on failure; nothing extra here.
      return null;
    }
    // If the page was popped during init, the caller will never get
    // a chance to assign this controller anywhere — release the
    // native device claim now so the next push doesn't hit device_busy.
    if (disposed) {
      Log.tag('camera').i(
        '_tryInitController completed after page dispose; releasing',
        fields: {'cameraId': description.id, 'audio': audio},
      );
      await ctrl.dispose();
      return null;
    }
    return ctrl;
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
          // Native picks between the in-app system prompt and a
          // Settings deep-link based on whether the OS will still
          // surface a prompt; either path lands here with the
          // post-call granted state. Refresh happens on
          // AppLifecycleState.resumed too, but poll directly on
          // return for snappier feedback when the user grants
          // and immediately comes back.
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
  void dispose() {
    controller.value?.dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget buildPresenter(BuildContext context) {
    if (MediaHost.current.isWideScreen(context)) return _buildDesktop(context);
    return _buildMobile(context);
  }

  Widget _buildDesktop(BuildContext context) {
    return GestureDetector(
      onTap: pop,
      child: Container(
        color: colors.scrim,
        child: Center(
          child: GestureDetector(
            onTap: () {},
            child: Card(
              color: const Color(0xFF000000),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 540),
                child: _buildContent(context),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMobile(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      body: _buildContent(context),
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
    final cameraAspect = MediaHost.current.isWideScreen(context) ? 4 / 3 : 3 / 4;

    return Stack(
      children: [
        SafeArea(
          child: Center(
            child: AspectRatio(
              aspectRatio: cameraAspect,
              child: CustomPaint(
                foregroundPainter: CameraGuidelinePainter(),
                child: Hero(
                  tag: 'camera',
                  child: CameraThumb(controller: controller),
                ),
              ),
            ),
          ),
        ),
        Dock.topLeft(
          child: Padding(
            padding: const EdgeInsets.only(left: 24, top: 48),
            child: _Rotating(
              orientation: orientation,
              child: FlashButton(
                onPress: toggleFlash,
                on: flashOn,
              ),
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
                        onPress: takePhoto,
                        onLongPress: recording ? null : takeVideo,
                      ),
                    ),
                  ),
                  _Rotating(
                    orientation: orientation,
                    child: Opacity(
                      opacity: recording ? 0 : 1,
                      child: _CircleButton(
                        onPress: recording ? null : flipCamera,
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
