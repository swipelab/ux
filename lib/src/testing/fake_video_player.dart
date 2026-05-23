import 'dart:async';
import 'dart:ui' show Size;

import 'package:ux/src/video/x_video_player.dart' show XDurationRange, XVideoPlayerException;
import 'package:ux/src/video/x_video_player_backend.dart';

/// In-memory backend for [XVideoPlayerController] tests. Swap in via
/// `XVideoPlayerBackend.instance = FakeXVideoPlayerBackend()` before
/// any UI mounts; restore with
/// `XVideoPlayerBackend.instance = MethodChannelXVideoPlayerBackend()`
/// in `tearDown`.
class FakeXVideoPlayerBackend implements XVideoPlayerBackend {
  FakeXVideoPlayerBackend({
    this.size = const Size(720, 1280),
    this.duration = const Duration(seconds: 10),
    this.rotationQuarterTurns = 0,
    this.textureIdSeed = 100,
  });

  // ---- captured calls ---------------------------------------------

  final List<String> createCalls = [];
  final List<int> initializeCalls = [];
  final List<int> disposeCalls = [];
  final List<int> playCalls = [];
  final List<int> pauseCalls = [];
  final List<({int handle, Duration position})> seekToCalls = [];
  final List<({int handle, bool loop})> setLoopingCalls = [];
  final List<({int handle, double volume})> setVolumeCalls = [];
  final List<({int handle, double rate})> setPlaybackSpeedCalls = [];

  // ---- configurable returns ---------------------------------------

  Size size;
  Duration duration;
  int rotationQuarterTurns;
  int textureIdSeed;

  /// If non-null, [create] throws this exception. Drives error paths.
  XVideoPlayerException? createError;
  XVideoPlayerException? initializeError;

  // ---- internal ---------------------------------------------------

  int _nextHandle = 1;
  final Map<int, StreamController<XVideoPlayerEvent>> _events = {};

  StreamController<XVideoPlayerEvent> _controllerFor(int handle) {
    return _events.putIfAbsent(
      handle,
      () => StreamController<XVideoPlayerEvent>.broadcast(),
    );
  }

  // ---- XVideoPlayerBackend ----------------------------------------

  @override
  Future<XVideoPlayerCreateResult> create({required String uri}) async {
    createCalls.add(uri);
    if (createError != null) throw createError!;
    final handle = _nextHandle++;
    _controllerFor(handle); // pre-warm
    return XVideoPlayerCreateResult(
      handle: handle,
      textureId: textureIdSeed + handle,
    );
  }

  @override
  Future<XVideoPlayerMetadata> initialize(int handle) async {
    initializeCalls.add(handle);
    if (initializeError != null) throw initializeError!;
    return XVideoPlayerMetadata(
      size: size,
      duration: duration,
      rotationQuarterTurns: rotationQuarterTurns,
    );
  }

  @override
  Future<void> disposeInstance(int handle) async {
    disposeCalls.add(handle);
    final controller = _events.remove(handle);
    await controller?.close();
  }

  @override
  Future<void> play(int handle) async {
    playCalls.add(handle);
    emitState(handle, isPlaying: true);
  }

  @override
  Future<void> pause(int handle) async {
    pauseCalls.add(handle);
    emitState(handle, isPlaying: false);
  }

  @override
  Future<void> seekTo(int handle, Duration position) async {
    seekToCalls.add((handle: handle, position: position));
    emitState(handle, position: position);
  }

  @override
  Future<void> setLooping(int handle, bool loop) async {
    setLoopingCalls.add((handle: handle, loop: loop));
  }

  @override
  Future<void> setVolume(int handle, double volume) async {
    setVolumeCalls.add((handle: handle, volume: volume));
  }

  @override
  Future<void> setPlaybackSpeed(int handle, double rate) async {
    setPlaybackSpeedCalls.add((handle: handle, rate: rate));
  }

  @override
  Stream<XVideoPlayerEvent> events(int handle) =>
      _controllerFor(handle).stream;

  // ---- test helpers ------------------------------------------------

  void emitState(
    int handle, {
    bool? isPlaying,
    bool? isBuffering,
    Duration? position,
    List<XDurationRange>? buffered,
  }) {
    _controllerFor(handle).add(
      XVideoPlayerStateChanged(
        handle,
        isPlaying: isPlaying,
        isBuffering: isBuffering,
        position: position,
        buffered: buffered,
      ),
    );
  }

  void emitSizeChanged(int handle, Size size) {
    _controllerFor(handle).add(XVideoPlayerSizeChanged(handle, size));
  }

  void emitCompleted(int handle) {
    _controllerFor(handle).add(XVideoPlayerCompleted(handle));
  }

  void emitError(int handle, String code, [String? description]) {
    _controllerFor(handle).add(XVideoPlayerError(handle, code, description));
  }
}
