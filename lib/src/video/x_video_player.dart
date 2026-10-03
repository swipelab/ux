import 'dart:async';
import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'x_video_player_backend.dart';
import 'x_video_player_view.dart' show XVideoPlayerView;

/// Throws when a [XVideoPlayerController] call fails on the platform
/// side. Maps from native `PlatformException` codes.
class XVideoPlayerException implements Exception {
  /// Binds the native error [code] and its optional message.
  const XVideoPlayerException(this.code, [this.description]);

  /// Stable identifier of the failure.
  final String code;

  /// Human-readable detail, where the native side supplied one.
  final String? description;

  @override
  String toString() =>
      'XVideoPlayerException($code${description == null ? '' : ': $description'})';
}

/// One contiguous range of buffered playback time. Matches the shape
/// `package:video_player` exposes today so call sites that read it
/// (gallery scrub bar) port mechanically.
class XDurationRange {
  /// Binds the span's bounds.
  const XDurationRange(this.start, this.end);

  /// Where the buffered span begins.
  final Duration start;

  /// Where the buffered span ends.
  final Duration end;
}

/// Immutable snapshot of an [XVideoPlayerController]'s state.
class XVideoPlayerValue {
  /// Binds a full state snapshot; every field defaults to its
  /// pre-initialize value.
  const XVideoPlayerValue({
    this.isInitialized = false,
    this.isPlaying = false,
    this.isBuffering = false,
    this.isLooping = false,
    this.rotationQuarterTurns = 0,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.size = Size.zero,
    this.volume = 1.0,
    this.playbackSpeed = 1.0,
    this.buffered = const [],
    this.errorDescription,
  });

  /// State of a player that has not been initialized.
  static const uninitialized = XVideoPlayerValue();

  /// Whether the native player has reported its metadata.
  final bool isInitialized;

  /// Whether the playhead is advancing.
  final bool isPlaying;

  /// Whether playback is stalled waiting on data.
  final bool isBuffering;

  /// Whether the track restarts on reaching its end.
  final bool isLooping;

  /// Quarter-turns of clockwise rotation [XVideoPlayerView] applies
  /// to the underlying `Texture`. Populated from the native side at
  /// initialize-time — Android always 0 (codec + GLES blit handle
  /// rotation natively), Apple non-zero when the asset's
  /// `preferredTransform` rotates the stored pixel buffer.
  final int rotationQuarterTurns;

  /// Last known playhead position. Reported by the native side on a
  /// fixed cadence (~10 Hz) — read this through a
  /// [ValueListenableBuilder] / `addListener` for live scrubbing.
  final Duration position;

  /// Total duration of the media. `Duration.zero` until [isInitialized].
  final Duration duration;

  /// Display-oriented dimensions of the video frame, after the track's
  /// rotation. `Size.zero` until the native side reports metadata.
  final Size size;

  /// Playback gain, from 0 to 1.
  final double volume;

  /// Playback rate, where 1 is real time.
  final double playbackSpeed;

  /// One range per contiguous buffered span. Empty before init; on
  /// local-file playback this is typically a single `[0..duration]`
  /// range that appears once the first frame is decoded.
  final List<XDurationRange> buffered;

  /// The last playback error's message, or `null` while healthy.
  final String? errorDescription;

  /// Whether [errorDescription] is set.
  bool get hasError => errorDescription != null;

  /// Aspect ratio with a graceful fall-through to 1:1 before the first
  /// frame is decoded. Compose / gallery wrap the player in
  /// `AspectRatio` and would otherwise divide by zero.
  double get aspectRatio {
    if (size.width <= 0 || size.height <= 0) return 1.0;
    return size.width / size.height;
  }

  /// This snapshot with the given fields replaced.
  XVideoPlayerValue copyWith({
    bool? isInitialized,
    bool? isPlaying,
    bool? isBuffering,
    bool? isLooping,
    int? rotationQuarterTurns,
    Duration? position,
    Duration? duration,
    Size? size,
    double? volume,
    double? playbackSpeed,
    List<XDurationRange>? buffered,
    Object? errorDescription = _unset,
  }) =>
      XVideoPlayerValue(
        isInitialized: isInitialized ?? this.isInitialized,
        isPlaying: isPlaying ?? this.isPlaying,
        isBuffering: isBuffering ?? this.isBuffering,
        isLooping: isLooping ?? this.isLooping,
        rotationQuarterTurns:
            rotationQuarterTurns ?? this.rotationQuarterTurns,
        position: position ?? this.position,
        duration: duration ?? this.duration,
        size: size ?? this.size,
        volume: volume ?? this.volume,
        playbackSpeed: playbackSpeed ?? this.playbackSpeed,
        buffered: buffered ?? this.buffered,
        errorDescription: identical(errorDescription, _unset)
            ? this.errorDescription
            : errorDescription as String?,
      );

  static const _unset = Object();
}

/// Owns one native video-player session. The surface mirrors the
/// subset of `package:video_player`'s `VideoPlayerController` the app
/// currently uses — the `.file(...)` / `.network(...)` constructors, the
/// standard playback controls, and the `value` getters compose /
/// gallery / outgoing-media read.
///
/// Lifecycle: construct → [initialize] → use → [dispose]. After
/// [dispose] every other method throws [XVideoPlayerException("disposed")],
/// and so does a call the native side answers after [dispose].
class XVideoPlayerController extends ChangeNotifier
    implements ValueListenable<XVideoPlayerValue> {
  /// Play a local file.
  XVideoPlayerController.file(io.File file) : _uri = 'file://${file.path}';

  /// Stream from a network URL. The native side hands the URI straight
  /// to Media3 (Android, `MediaItem.fromUri`) / `AVURLAsset` (Apple),
  /// both of which stream http(s) natively — no extra setup.
  XVideoPlayerController.network(Uri uri) : _uri = uri.toString();

  /// Fully-qualified source URI handed to the native side at
  /// [initialize]. `file://...` for [XVideoPlayerController.file], the
  /// raw URL for [XVideoPlayerController.network].
  final String _uri;

  XVideoPlayerValue _value = XVideoPlayerValue.uninitialized;

  @override
  XVideoPlayerValue get value => _value;

  set _setValue(XVideoPlayerValue next) {
    if (identical(_value, next)) return;
    _value = next;
    notifyListeners();
  }

  int? _handle;
  int? _textureId;
  StreamSubscription<XVideoPlayerEvent>? _eventsSub;
  bool _disposed = false;
  Completer<void>? _initCompleter;

  /// Native handle once [initialize] has resolved. Null otherwise.
  int? get handle => _handle;

  /// Texture id on Apple platforms. On Android playback uses a platform
  /// view (no texture id), and this stays null.
  int? get textureId => _textureId;

  /// Configure the native session and load the file. Resolves once the
  /// codec is ready and `value.size` / `value.duration` are populated.
  /// Throws if the file is missing, unreadable, or unsupported.
  Future<void> initialize() {
    _throwIfDisposed('initialize');
    final existing = _initCompleter;
    if (existing != null) return existing.future;
    final completer = Completer<void>();
    _initCompleter = completer;
    _initInternal().then(
      (_) => completer.complete(),
      onError: completer.completeError,
    );
    return completer.future;
  }

  Future<void> _initInternal() async {
    try {
      final result = await XVideoPlayerBackend.instance.create(
        uri: _uri,
      );
      if (_disposed) await _disposeInstance(result.handle);
      _throwIfDisposed('initialize');
      _handle = result.handle;
      _textureId = result.textureId;
      _eventsSub = XVideoPlayerBackend.instance.events(result.handle).listen(
            _onEvent,
            onError: (Object error, StackTrace? stack) {
              _setValue = _value.copyWith(errorDescription: error.toString());
            },
          );
      final metadata = await _send(
        'initialize',
        (backend, handle) => backend.initialize(handle),
      );
      _setValue = _value.copyWith(
        isInitialized: true,
        size: metadata.size,
        duration: metadata.duration,
        rotationQuarterTurns: metadata.rotationQuarterTurns,
      );
    } catch (_) {
      // Tear down anything the native side allocated mid-failure so a
      // retry isn't blocked by leaked resources.
      await dispose();
      rethrow;
    }
  }

  void _onEvent(XVideoPlayerEvent event) {
    switch (event) {
      case XVideoPlayerStateChanged(
          :final isPlaying,
          :final isBuffering,
          :final position,
          :final buffered
        ):
        _setValue = _value.copyWith(
          isPlaying: isPlaying ?? _value.isPlaying,
          isBuffering: isBuffering ?? _value.isBuffering,
          position: position ?? _value.position,
          buffered: buffered ?? _value.buffered,
        );
      case XVideoPlayerSizeChanged(:final size):
        _setValue = _value.copyWith(size: size);
      case XVideoPlayerCompleted():
        if (!_value.isLooping) {
          _setValue = _value.copyWith(isPlaying: false);
        }
      case XVideoPlayerError(:final code, :final description):
        _setValue = _value.copyWith(errorDescription: description ?? code);
    }
  }

  /// Starts or resumes playback.
  Future<void> play() async {
    await _send('play', (backend, handle) => backend.play(handle));
    _setValue = _value.copyWith(isPlaying: true);
  }

  /// Halts playback, leaving the playhead where it is.
  Future<void> pause() async {
    await _send('pause', (backend, handle) => backend.pause(handle));
    _setValue = _value.copyWith(isPlaying: false);
  }

  /// Moves the playhead, clamped into the track.
  Future<void> seekTo(Duration position) async {
    final clamped = position < Duration.zero
        ? Duration.zero
        : position > _value.duration && _value.duration > Duration.zero
            ? _value.duration
            : position;
    await _send(
      'seekTo',
      (backend, handle) => backend.seekTo(handle, clamped),
    );
    _setValue = _value.copyWith(position: clamped);
  }

  /// Sets whether the track restarts on reaching its end.
  Future<void> setLooping(bool loop) async {
    await _send(
      'setLooping',
      (backend, handle) => backend.setLooping(handle, loop),
    );
    _setValue = _value.copyWith(isLooping: loop);
  }

  /// Sets playback gain, clamped to 0–1.
  Future<void> setVolume(double volume) async {
    final clamped = volume.clamp(0.0, 1.0).toDouble();
    await _send(
      'setVolume',
      (backend, handle) => backend.setVolume(handle, clamped),
    );
    _setValue = _value.copyWith(volume: clamped);
  }

  /// Sets playback rate, clamped to 0.25–4.
  Future<void> setPlaybackSpeed(double rate) async {
    final clamped = rate.clamp(0.25, 4.0).toDouble();
    await _send(
      'setPlaybackSpeed',
      (backend, handle) => backend.setPlaybackSpeed(handle, clamped),
    );
    _setValue = _value.copyWith(playbackSpeed: clamped);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final handle = _handle;
    _handle = null;
    final cancelled = _eventsSub?.cancel();
    _eventsSub = null;
    if (handle != null) await _disposeInstance(handle);
    await cancelled;
    super.dispose();
  }

  Future<void> _disposeInstance(int handle) async {
    try {
      await XVideoPlayerBackend.instance.disposeInstance(handle);
    } on XVideoPlayerException {
      // The native side may already have torn down, e.g. while the engine
      // detaches; dispose completes regardless.
    }
  }

  /// Runs [call] against the native session and fails with `disposed`
  /// when [dispose] ran before the native side answered.
  Future<T> _send<T>(
    String op,
    Future<T> Function(XVideoPlayerBackend backend, int handle) call,
  ) async {
    final result = await call(XVideoPlayerBackend.instance, _requireHandle(op));
    _throwIfDisposed(op);
    return result;
  }

  /// Texture-backed (Apple) or platform-view-backed (Android) render
  /// widget. Equivalent to `VideoPlayer(controller)` — wrap in
  /// `AspectRatio` to control framing.
  Widget buildPlayer() => XVideoPlayerView(controller: this);

  int _requireHandle(String op) {
    _throwIfDisposed(op);
    final h = _handle;
    if (h == null) {
      throw const XVideoPlayerException('not_initialized');
    }
    return h;
  }

  void _throwIfDisposed(String op) {
    if (_disposed) {
      throw XVideoPlayerException(
        'disposed',
        '$op called on a disposed controller',
      );
    }
  }
}
