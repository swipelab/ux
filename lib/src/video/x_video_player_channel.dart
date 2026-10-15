import 'dart:async';

import 'package:flutter/services.dart';

import 'x_video_player.dart' show XDurationRange, XVideoPlayerException;
import 'x_video_player_backend.dart';

/// Production [XVideoPlayerBackend]. Hand-rolled MethodChannel +
/// EventChannel — matches the rest of `package:ux`, no pigeon.
class MethodChannelXVideoPlayerBackend implements XVideoPlayerBackend {
  /// Creates a backend bound to the `ux/video` channels.
  MethodChannelXVideoPlayerBackend();

  static const _channel = MethodChannel('ux/video');
  static const _eventsChannel = EventChannel('ux/video/events');

  late final Stream<Object?> _rawEvents = _eventsChannel
      .receiveBroadcastStream();

  @override
  Future<XVideoPlayerCreateResult> create({required String uri}) async {
    final m = await _invokeMap('create', {'uri': uri});
    return XVideoPlayerCreateResult(
      handle: (m['handle'] as num).toInt(),
      textureId: (m['textureId'] as num?)?.toInt(),
    );
  }

  @override
  Future<XVideoPlayerMetadata> initialize(int handle) async {
    final m = await _invokeMap('initialize', {'handle': handle});
    final s = (m['size'] as Map).cast<Object?, Object?>();
    return XVideoPlayerMetadata(
      size: Size(
        (s['width'] as num).toDouble(),
        (s['height'] as num).toDouble(),
      ),
      duration: Duration(milliseconds: (m['durationMs'] as num).toInt()),
      rotationQuarterTurns: (m['rotationQuarterTurns'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<void> disposeInstance(int handle) =>
      _invokeVoid('dispose', {'handle': handle});

  @override
  Future<void> play(int handle) => _invokeVoid('play', {'handle': handle});

  @override
  Future<void> pause(int handle) => _invokeVoid('pause', {'handle': handle});

  @override
  Future<void> seekTo(int handle, Duration position) => _invokeVoid('seekTo', {
    'handle': handle,
    'positionMs': position.inMilliseconds,
  });

  @override
  Future<void> setLooping(int handle, bool loop) =>
      _invokeVoid('setLooping', {'handle': handle, 'loop': loop});

  @override
  Future<void> setVolume(int handle, double volume) =>
      _invokeVoid('setVolume', {'handle': handle, 'volume': volume});

  @override
  Future<void> setPlaybackSpeed(int handle, double rate) =>
      _invokeVoid('setPlaybackSpeed', {'handle': handle, 'rate': rate});

  @override
  Stream<XVideoPlayerEvent> events(int handle) {
    return _rawEvents
        .map((e) => (e as Map).cast<Object?, Object?>())
        .where((m) => (m['handle'] as num).toInt() == handle)
        .map(_decodeEvent);
  }

  // ---- parsers / arg encoders -------------------------------------

  static XVideoPlayerEvent _decodeEvent(Map<Object?, Object?> m) {
    final handle = (m['handle'] as num).toInt();
    switch (m['event'] as String?) {
      case 'stateChanged':
        return XVideoPlayerStateChanged(
          handle,
          isPlaying: m['isPlaying'] as bool?,
          isBuffering: m['isBuffering'] as bool?,
          position: _parseMs(m['positionMs']),
          buffered: _parseBuffered(m['buffered']),
        );
      case 'sizeChanged':
        final s = (m['size'] as Map).cast<Object?, Object?>();
        return XVideoPlayerSizeChanged(
          handle,
          Size((s['width'] as num).toDouble(), (s['height'] as num).toDouble()),
        );
      case 'completed':
        return XVideoPlayerCompleted(handle);
      case 'error':
        return XVideoPlayerError(
          handle,
          m['code'] as String? ?? 'player_runtime_error',
          m['description'] as String?,
        );
      default:
        return XVideoPlayerError(handle, 'unknown_event', null);
    }
  }

  static Duration? _parseMs(Object? raw) {
    if (raw == null) return null;
    return Duration(milliseconds: (raw as num).toInt());
  }

  static List<XDurationRange>? _parseBuffered(Object? raw) {
    if (raw == null) return null;
    return [
      for (final r in (raw as List).cast<Map<Object?, Object?>>())
        XDurationRange(
          Duration(milliseconds: (r['startMs'] as num).toInt()),
          Duration(milliseconds: (r['endMs'] as num).toInt()),
        ),
    ];
  }

  // ---- channel adapter --------------------------------------------

  Future<Map<Object?, Object?>> _invokeMap(
    String method, [
    Map<String, Object?>? args,
  ]) async {
    try {
      final result = await _channel.invokeMethod<Object?>(method, args);
      return (result as Map).cast<Object?, Object?>();
    } on PlatformException catch (e) {
      throw XVideoPlayerException(e.code, e.message);
    }
  }

  Future<void> _invokeVoid(String method, [Map<String, Object?>? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on PlatformException catch (e) {
      throw XVideoPlayerException(e.code, e.message);
    }
  }
}
