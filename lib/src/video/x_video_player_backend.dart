import 'dart:async';
import 'dart:ui' show Size;

import 'x_video_player.dart' show XDurationRange;
import 'x_video_player_channel.dart' show MethodChannelXVideoPlayerBackend;

/// Backend contract that [XVideoPlayerController] dispatches into. The
/// default implementation calls into native code via the `ux/video` /
/// `ux/video/events` channels; tests substitute their own (see
/// `package:ux/testing.dart`'s `FakeXVideoPlayerBackend`).
///
/// Every per-instance call carries a `handle` returned by [create] so
/// the plugin can route to the right native session. Multiple
/// controllers can hold simultaneous handles.
abstract class XVideoPlayerBackend {
  /// Swap to inject a fake before any UI code mounts a controller.
  static XVideoPlayerBackend instance = MethodChannelXVideoPlayerBackend();

  /// Allocate a native player instance bound to [uri] (currently always
  /// `file://...`). Returns the handle and, on Apple platforms, the
  /// Flutter texture id; Android returns `textureId: null` because the
  /// render path is a platform view that takes the handle as creation
  /// params.
  Future<XVideoPlayerCreateResult> create({required String uri});

  /// Load the media. Resolves once the codec is configured and metadata
  /// (size, duration) is known. Throws
  /// [XVideoPlayerException("decode_failed")] if the file can't be
  /// opened or the codec init failed permanently.
  Future<XVideoPlayerMetadata> initialize(int handle);

  /// Tear down the session. Releases the codec and any held surface /
  /// texture. Safe to call repeatedly; no-op once disposed.
  Future<void> disposeInstance(int handle);

  Future<void> play(int handle);
  Future<void> pause(int handle);
  Future<void> seekTo(int handle, Duration position);
  Future<void> setLooping(int handle, bool loop);
  Future<void> setVolume(int handle, double volume);
  Future<void> setPlaybackSpeed(int handle, double rate);

  /// Live event stream for [handle]. The controller subscribes during
  /// [create] / [initialize] and unsubscribes on [disposeInstance].
  Stream<XVideoPlayerEvent> events(int handle);
}

/// The tuple returned by [XVideoPlayerBackend.create] — everything the
/// controller needs to start the load + route subsequent calls.
class XVideoPlayerCreateResult {
  const XVideoPlayerCreateResult({
    required this.handle,
    this.textureId,
  });

  final int handle;

  /// Apple-platform Flutter texture id, or null on Android (which uses
  /// a platform view keyed off [handle] instead).
  final int? textureId;
}

/// Media metadata returned by [XVideoPlayerBackend.initialize] once the
/// codec is ready.
class XVideoPlayerMetadata {
  const XVideoPlayerMetadata({
    required this.size,
    required this.duration,
    this.rotationQuarterTurns = 0,
  });

  final Size size;
  final Duration duration;

  /// Number of 90° clockwise rotations the Flutter `Texture` widget
  /// needs so the rendered frame reads upright. Android always
  /// reports 0 (the codec + GLES blit apply the rotation upstream of
  /// Flutter). Apple reports the rotation derived from the video
  /// track's `preferredTransform` — `AVPlayerItemVideoOutput`
  /// delivers pixel buffers in the file's natural orientation, so the
  /// `RotatedBox` wrapper applies it Dart-side.
  final int rotationQuarterTurns;
}

/// Events pushed by the native side over `ux/video/events`. Sealed —
/// new variants land here as the contract grows.
sealed class XVideoPlayerEvent {
  const XVideoPlayerEvent(this.handle);
  final int handle;
}

/// Periodic + edge-triggered state update. Any field may be null,
/// meaning "no change since the last snapshot." Position is included
/// on every emit; the rest are emitted on transition.
class XVideoPlayerStateChanged extends XVideoPlayerEvent {
  const XVideoPlayerStateChanged(
    super.handle, {
    this.isPlaying,
    this.isBuffering,
    this.position,
    this.buffered,
  });

  final bool? isPlaying;
  final bool? isBuffering;
  final Duration? position;
  final List<XDurationRange>? buffered;
}

/// Fired when the codec reports a video-size change. Usually exactly
/// once shortly after the first frame is decoded; some adaptive
/// streams emit it on resolution changes (not in scope for the
/// file-only constructor today but the event remains valid).
class XVideoPlayerSizeChanged extends XVideoPlayerEvent {
  const XVideoPlayerSizeChanged(super.handle, this.size);
  final Size size;
}

/// Fired when playback hits the end of the media. Loop-mode is
/// observed natively, so the controller only sees this event when
/// playback truly stops at the tail.
class XVideoPlayerCompleted extends XVideoPlayerEvent {
  const XVideoPlayerCompleted(super.handle);
}

/// Terminal error. The controller marks the value as `hasError = true`
/// and stops emitting state updates until [XVideoPlayerBackend.disposeInstance].
class XVideoPlayerError extends XVideoPlayerEvent {
  const XVideoPlayerError(super.handle, this.code, this.description);
  final String code;
  final String? description;
}
