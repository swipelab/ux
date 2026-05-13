import 'dart:async';

import 'package:flutter/services.dart';

import '../file.dart' show UxFile;
import 'camera.dart'
    show
        UxCameraDescription,
        UxCameraException,
        UxCameraLens,
        UxFlashMode,
        UxResolutionPreset;
import 'camera_backend.dart';

/// Production [UxCameraBackend]. Hand-rolled MethodChannel +
/// EventChannel — matches the rest of `package:ux`, no pigeon.
class MethodChannelUxCameraBackend implements UxCameraBackend {
  MethodChannelUxCameraBackend();

  static const _channel = MethodChannel('ux/camera');
  static const _eventsChannel = EventChannel('ux/camera/events');

  /// Single broadcast stream over the native event channel. We
  /// demultiplex per-handle inside [events] so a Stream subscription
  /// is cheap (no per-instance EventChannel hop).
  late final Stream<Object?> _rawEvents =
      _eventsChannel.receiveBroadcastStream();

  @override
  Future<List<UxCameraDescription>> availableCameras() async {
    final raw = await _invoke<List<Object?>>('availableCameras');
    return raw.map((e) {
      final m = (e as Map).cast<Object?, Object?>();
      return UxCameraDescription(
        id: m['id'] as String,
        lens: _parseLens(m['lens'] as String?),
        sensorOrientation: (m['sensorOrientation'] as num?)?.toInt() ?? 0,
      );
    }).toList(growable: false);
  }

  @override
  Future<UxCameraCreateResult> create({
    required String cameraId,
    required bool enableAudio,
    required UxResolutionPreset preset,
  }) async {
    final m = await _invokeMap('create', {
      'cameraId': cameraId,
      'enableAudio': enableAudio,
      'preset': _presetArg(preset),
    });
    final size = (m['previewSize'] as Map).cast<Object?, Object?>();
    return UxCameraCreateResult(
      handle: (m['handle'] as num).toInt(),
      textureId: (m['textureId'] as num).toInt(),
      previewSize: Size(
        (size['width'] as num).toDouble(),
        (size['height'] as num).toDouble(),
      ),
    );
  }

  @override
  Future<void> initialize(int handle) =>
      _invokeVoid('initialize', {'handle': handle});

  @override
  Future<void> disposeInstance(int handle) =>
      _invokeVoid('dispose', {'handle': handle});

  @override
  Future<Size> setDescription(int handle, String cameraId) async {
    final m = await _invokeMap('setDescription', {
      'handle': handle,
      'cameraId': cameraId,
    });
    final s = (m['previewSize'] as Map).cast<Object?, Object?>();
    return Size(
      (s['width'] as num).toDouble(),
      (s['height'] as num).toDouble(),
    );
  }

  @override
  Future<void> setFlashMode(int handle, UxFlashMode mode) =>
      _invokeVoid('setFlashMode', {
        'handle': handle,
        'mode': _flashArg(mode),
      });

  @override
  Future<void> lockCaptureOrientation(
    int handle,
    DeviceOrientation orientation,
  ) =>
      _invokeVoid('lockCaptureOrientation', {
        'handle': handle,
        'orientation': _orientationArg(orientation),
      });

  @override
  Future<void> unlockCaptureOrientation(int handle) =>
      _invokeVoid('unlockCaptureOrientation', {'handle': handle});

  @override
  Future<UxFile> takePicture(
    int handle,
    DeviceOrientation snapshotOrientation,
  ) async {
    final m = await _invokeMap('takePicture', {
      'handle': handle,
      'snapshotOrientation': _orientationArg(snapshotOrientation),
    });
    return UxFile(m['path'] as String);
  }

  @override
  Future<void> startVideoRecording(
    int handle,
    DeviceOrientation snapshotOrientation,
  ) =>
      _invokeVoid('startVideoRecording', {
        'handle': handle,
        'snapshotOrientation': _orientationArg(snapshotOrientation),
      });

  @override
  Future<UxFile> stopVideoRecording(int handle) async {
    final m = await _invokeMap('stopVideoRecording', {'handle': handle});
    return UxFile(m['path'] as String);
  }

  @override
  Stream<UxCameraEvent> events(int handle) {
    return _rawEvents
        .map((e) => (e as Map).cast<Object?, Object?>())
        .where((m) => (m['handle'] as num).toInt() == handle)
        .map(_decodeEvent);
  }

  // ---- parsers / arg encoders -------------------------------------

  static UxCameraEvent _decodeEvent(Map<Object?, Object?> m) {
    final handle = (m['handle'] as num).toInt();
    switch (m['event'] as String?) {
      case 'deviceOrientationChanged':
        return UxCameraDeviceOrientationChanged(
          handle,
          _parseOrientation(m['orientation'] as String?),
        );
      case 'sessionError':
        return UxCameraSessionError(
          handle,
          m['code'] as String? ?? 'session_runtime_error',
          m['description'] as String?,
        );
      case 'sessionInterrupted':
        return UxCameraSessionInterrupted(
          handle,
          m['reason'] as String? ?? '',
        );
      case 'sessionResumed':
        return UxCameraSessionResumed(handle);
      default:
        return UxCameraSessionError(handle, 'unknown_event', null);
    }
  }

  static UxCameraLens _parseLens(String? raw) => switch (raw) {
        'front' => UxCameraLens.front,
        _ => UxCameraLens.back,
      };

  static DeviceOrientation _parseOrientation(String? raw) => switch (raw) {
        'landscapeLeft' => DeviceOrientation.landscapeLeft,
        'landscapeRight' => DeviceOrientation.landscapeRight,
        'portraitDown' => DeviceOrientation.portraitDown,
        _ => DeviceOrientation.portraitUp,
      };

  static String _orientationArg(DeviceOrientation o) => switch (o) {
        DeviceOrientation.portraitUp => 'portraitUp',
        DeviceOrientation.landscapeLeft => 'landscapeLeft',
        DeviceOrientation.portraitDown => 'portraitDown',
        DeviceOrientation.landscapeRight => 'landscapeRight',
      };

  static String _flashArg(UxFlashMode m) => switch (m) {
        UxFlashMode.off => 'off',
        UxFlashMode.always => 'always',
      };

  static String _presetArg(UxResolutionPreset p) => switch (p) {
        UxResolutionPreset.high => 'high',
      };

  // ---- channel adapter --------------------------------------------

  Future<T> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      final result = await _channel.invokeMethod<Object?>(method, args);
      return result as T;
    } on PlatformException catch (e) {
      throw UxCameraException(e.code, e.message);
    }
  }

  Future<Map<Object?, Object?>> _invokeMap(
    String method, [
    Map<String, Object?>? args,
  ]) async {
    final result = await _invoke<Map<Object?, Object?>>(method, args);
    return result;
  }

  Future<void> _invokeVoid(String method, [Map<String, Object?>? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on PlatformException catch (e) {
      throw UxCameraException(e.code, e.message);
    }
  }
}
