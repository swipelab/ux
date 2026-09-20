import 'dart:async';

import 'package:flutter/services.dart';

import 'package:ux/src/file.dart' show XFile;
import 'package:ux/src/log.dart' show Log;
import 'package:ux/src/camera/camera.dart'
    show
        XCameraDescription,
        XCameraException,
        XCameraLens,
        XFlashMode,
        XResolutionPreset;
import 'package:ux/src/camera/camera_backend.dart';

final _log = Log.tag('camera');

/// Production [XCameraBackend]. Hand-rolled MethodChannel +
/// EventChannel — matches the rest of `package:ux`, no pigeon.
class MethodChannelXCameraBackend implements XCameraBackend {
  /// Creates a backend bound to the `ux/camera` channels.
  MethodChannelXCameraBackend();

  static const _channel = MethodChannel('ux/camera');
  static const _eventsChannel = EventChannel('ux/camera/events');

  /// Single broadcast stream over the native event channel. We
  /// demultiplex per-handle inside [events] so a Stream subscription
  /// is cheap (no per-instance EventChannel hop).
  late final Stream<Object?> _rawEvents = () {
    final stream = _eventsChannel.receiveBroadcastStream();
    // Plugin-level diagnostics (handle == -1) flow over the same
    // channel but aren't claimed by any controller's per-handle
    // filter. Subscribe once globally so they reach `ux.Log` (and
    // therefore the log_server jsonl) even before any controller
    // is alive.
    stream.listen((e) {
      final m = (e as Map).cast<Object?, Object?>();
      if (m['event'] != 'diagnostic') return;
      if ((m['handle'] as num?)?.toInt() != -1) return;
      _log.i('plugin: ${m['message'] ?? ''}');
    });
    return stream;
  }();

  @override
  Future<List<XCameraDescription>> availableCameras() async {
    final raw = await _invoke<List<Object?>>('availableCameras');
    return raw.map((e) {
      final m = (e as Map).cast<Object?, Object?>();
      return XCameraDescription(
        id: m['id'] as String,
        lens: _parseLens(m['lens'] as String?),
        sensorOrientation: (m['sensorOrientation'] as num?)?.toInt() ?? 0,
      );
    }).toList(growable: false);
  }

  @override
  Future<XCameraCreateResult> create({
    required String cameraId,
    required bool enableAudio,
    required XResolutionPreset preset,
  }) async {
    final m = await _invokeMap('create', {
      'cameraId': cameraId,
      'enableAudio': enableAudio,
      'preset': _presetArg(preset),
    });
    final size = (m['previewSize'] as Map).cast<Object?, Object?>();
    return XCameraCreateResult(
      handle: (m['handle'] as num).toInt(),
      textureId: (m['textureId'] as num).toInt(),
      previewSize: Size(
        (size['width'] as num).toDouble(),
        (size['height'] as num).toDouble(),
      ),
      previewRotationQuarterTurns:
          (m['previewRotationQuarterTurns'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<void> initialize(int handle) =>
      _invokeVoid('initialize', {'handle': handle});

  @override
  Future<void> disposeInstance(int handle) =>
      _invokeVoid('dispose', {'handle': handle});

  @override
  Future<({Size previewSize, int previewRotationQuarterTurns})> setDescription(
    int handle,
    String cameraId,
  ) async {
    final m = await _invokeMap('setDescription', {
      'handle': handle,
      'cameraId': cameraId,
    });
    final s = (m['previewSize'] as Map).cast<Object?, Object?>();
    return (
      previewSize: Size(
        (s['width'] as num).toDouble(),
        (s['height'] as num).toDouble(),
      ),
      previewRotationQuarterTurns:
          (m['previewRotationQuarterTurns'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<void> setFlashMode(int handle, XFlashMode mode) =>
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
  Future<XFile> takePicture(
    int handle,
    DeviceOrientation snapshotOrientation,
  ) async {
    final m = await _invokeMap('takePicture', {
      'handle': handle,
      'snapshotOrientation': _orientationArg(snapshotOrientation),
    });
    return XFile(m['path'] as String);
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
  Future<XFile> stopVideoRecording(int handle) async {
    final m = await _invokeMap('stopVideoRecording', {'handle': handle});
    return XFile(m['path'] as String);
  }

  @override
  Future<bool> cameraPermissionGranted() =>
      _invoke<bool>('cameraPermissionStatus');

  @override
  Future<bool> requestCameraPermission() =>
      _invoke<bool>('requestCameraPermission');

  @override
  Future<bool> audioPermissionGranted() => _invoke<bool>('audioPermissionStatus');

  @override
  Future<bool> requestAudioPermission() => _invoke<bool>('requestAudioPermission');

  @override
  Future<void> openSettings() => _invokeVoid('openSettings');

  @override
  Stream<XCameraEvent> events(int handle) {
    return _rawEvents
        .map((e) => (e as Map).cast<Object?, Object?>())
        .where((m) => (m['handle'] as num).toInt() == handle)
        .map(_decodeEvent);
  }

  // ---- parsers / arg encoders -------------------------------------

  static XCameraEvent _decodeEvent(Map<Object?, Object?> m) {
    final handle = (m['handle'] as num).toInt();
    switch (m['event'] as String?) {
      case 'deviceOrientationChanged':
        return XCameraDeviceOrientationChanged(
          handle,
          _parseOrientation(m['orientation'] as String?),
        );
      case 'sessionError':
        return XCameraSessionError(
          handle,
          m['code'] as String? ?? 'session_runtime_error',
          m['description'] as String?,
        );
      case 'sessionInterrupted':
        return XCameraSessionInterrupted(
          handle,
          m['reason'] as String? ?? '',
        );
      case 'sessionResumed':
        return XCameraSessionResumed(handle);
      case 'diagnostic':
        return XCameraDiagnostic(
          handle,
          m['message'] as String? ?? '',
        );
      case 'previewSizeChanged':
        final s = (m['previewSize'] as Map).cast<Object?, Object?>();
        return XCameraPreviewSizeChanged(
          handle,
          Size(
            (s['width'] as num).toDouble(),
            (s['height'] as num).toDouble(),
          ),
        );
      default:
        return XCameraSessionError(handle, 'unknown_event', null);
    }
  }

  static XCameraLens _parseLens(String? raw) => switch (raw) {
        'front' => XCameraLens.front,
        _ => XCameraLens.back,
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

  static String _flashArg(XFlashMode m) => switch (m) {
        XFlashMode.off => 'off',
        XFlashMode.always => 'always',
      };

  static String _presetArg(XResolutionPreset p) => switch (p) {
        XResolutionPreset.high => 'high',
      };

  // ---- channel adapter --------------------------------------------

  Future<T> _invoke<T>(String method, [Map<String, Object?>? args]) async {
    try {
      final result = await _channel.invokeMethod<Object?>(method, args);
      return result as T;
    } on PlatformException catch (e) {
      throw XCameraException(e.code, e.message);
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
      throw XCameraException(e.code, e.message);
    }
  }
}
