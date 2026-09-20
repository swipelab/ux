import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:ux/camera.dart';
import 'package:ux/log.dart';

/// Owns the controller and its replacements; borrowers listen without disposing.
class CameraSession extends ChangeNotifier
    implements ValueListenable<XCameraController?> {
  XCameraController? _controller;
  List<XCameraDescription> _cameras = const [];
  Future<void> _pending = Future.value();
  Future<void>? _disposal;
  bool _closed = false;

  @override
  XCameraController? get value => _controller;

  /// Discovery results, empty until initialization or when no device is available.
  List<XCameraDescription> get cameras => _cameras;

  /// Whether new work is refused, including while native release is pending.
  bool get disposed => _closed;

  Future<T?> _enqueue<T>(Future<T?> Function() operation) {
    if (_closed) return Future.value();
    final result = _pending.then((_) => _closed ? null : operation());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  void _publish(XCameraController? controller) {
    if (_closed) return;
    _controller = controller;
    notifyListeners();
  }

  /// Reuses an open controller, or opens the front camera when available.
  Future<XCameraController?> initialize() => _enqueue(() async {
    if (_controller != null) return _controller;
    _cameras = List.unmodifiable(await uxAvailableCameras());
    if (_closed || _cameras.isEmpty) return null;
    final camera = _cameras.firstWhere(
      (camera) => camera.lens == XCameraLens.front,
      orElse: () => _cameras.first,
    );
    return _open(camera, XResolutionPreset.high, audio: false);
  });

  Future<XCameraController?> _open(
    XCameraDescription description,
    XResolutionPreset preset, {
    required bool audio,
  }) async {
    final controller = XCameraController(
      description,
      preset,
      enableAudio: audio,
    );
    var retained = false;
    try {
      await controller.initialize();
      if (_closed) return null;
      await controller.lockCaptureOrientation(DeviceOrientation.portraitUp);
      if (_closed) return null;
      retained = true;
      _publish(controller);
      return _closed ? null : controller;
    } finally {
      if (!retained) await controller.dispose();
    }
  }

  /// Serializes use with lens changes, replacement and native disposal.
  Future<T?> useController<T>(
    Future<T> Function(XCameraController) operation,
  ) => _enqueue(() async {
    final controller = _controller;
    if (controller == null) return null;
    return operation(controller);
  });

  /// Changes lens on the current controller unless it is recording.
  Future<void> flipCamera() => useController((controller) async {
    if (controller.value.isRecordingVideo) return;
    final other = _cameras.firstWhereOrNull(
      (camera) => camera.lens != controller.description.lens,
    );
    if (other == null) return;
    await controller.setDescription(other);
    await controller.lockCaptureOrientation(DeviceOrientation.portraitUp);
    if (!_closed) notifyListeners();
  });

  /// Reopens the current lens with audio, retaining silent capture on failure.
  Future<XCameraController?> ensureAudio() => _enqueue(() async {
    final current = _controller;
    if (current == null || current.enableAudio) return current;
    final description = current.description;
    final preset = current.resolutionPreset;
    _publish(null);
    await current.dispose();
    if (_closed) return null;

    XCameraController? next;
    try {
      next = await _open(description, preset, audio: true);
    } on XCameraException catch (error, stack) {
      Log.tag('camera')
          .w('audio camera failed', error: error, stackTrace: stack);
      if (_closed) return null;
      next = await _open(description, preset, audio: false);
    }
    return next;
  });

  /// Ends an active recording without closing the preview.
  Future<void> stopRecording() => useController((controller) async {
    if (controller.value.isRecordingVideo) {
      await controller.stopVideoRecording();
    }
  });

  /// Closes immediately to new work; completes after native work and release.
  @override
  Future<void> dispose() {
    if (_disposal != null) return _disposal!;
    _closed = true;
    final controller = _controller;
    _controller = null;
    notifyListeners();
    super.dispose();
    return _disposal = _pending.then((_) async => controller?.dispose());
  }
}
