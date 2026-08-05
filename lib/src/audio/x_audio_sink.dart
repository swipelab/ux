import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show
        ErrorDescription,
        FlutterError,
        FlutterErrorDetails,
        TargetPlatform,
        ValueListenable,
        defaultTargetPlatform,
        kIsWeb;
import 'package:flutter/services.dart';

import 'package:ux/src/core/emitter.dart';

/// Lifecycle of the playback queue.
enum XAudioSinkState {
  /// Nothing queued: either no audio has been enqueued yet, the queue has
  /// drained, or [XAudioSink.flush] emptied it.
  idle,

  /// Audio is queued and playing.
  playing,

  /// The OS took the output away — an interruption, or the output device
  /// disappearing. Queued audio is gone; the caller decides when to
  /// [XAudioSink.enqueue] again.
  interrupted,
}

/// Thrown by [XAudioSink.enqueue] when the output cannot open.
///
/// [code] is one of `no_output_device`, `start_failed`, or `unsupported`.
class XAudioSinkException implements Exception {
  /// Creates an exception with a wire [code] and an optional [message].
  const XAudioSinkException(this.code, [this.message]);

  /// Machine-readable failure kind.
  final String code;

  /// Platform-supplied detail, when there is one.
  final String? message;

  @override
  String toString() => 'XAudioSinkException($code, $message)';
}

/// Push-based playback of mono 16 kHz Int16 PCM: [enqueue] chunks as they
/// arrive and they play back-to-back, starting before the stream ends.
///
/// The sink is a *writer* on the output, not an owner of the route: Apple
/// schedules buffers on an `AVAudioPlayerNode`, Android streams into an
/// `AudioTrack` on the media usage. Neither claims the communication route
/// nor takes audio focus, so a call in progress keeps its routing.
///
/// ```dart
/// final sink = XAudioSink.instance;
/// await for (final chunk in ttsSocket) {
///   await sink.enqueue(chunk);
/// }
/// await sink.drained.first;
/// ```
///
/// [enqueue] resolves once the platform holds the chunk, not when it is
/// audible. [flush] cancels everything still queued — including chunks this
/// Dart side has not handed over yet — and releases the output; the next
/// [enqueue] reopens it. A queue that empties on its own leaves the output
/// open, so the next chunk of a conversation starts without a device warm-up.
abstract interface class XAudioSink {
  /// The process-wide sink. One output, one instance.
  static final XAudioSink instance = MethodChannelXAudioSink();

  /// Sample rate every enqueued chunk is interpreted at.
  static const int sampleRate = 16000;

  /// Whether this platform has a native sink. Elsewhere [enqueue] throws
  /// `unsupported` and [state] stays [XAudioSinkState.idle].
  bool get supported;

  /// Fires each time the queue plays out completely. A broadcast stream;
  /// [flush] cancels queued audio rather than draining it, so it does not
  /// fire one.
  Stream<void> get drained;

  /// Current lifecycle state, driven by the native sink.
  ValueListenable<XAudioSinkState> get state;

  /// Appends [samples] — mono Int16 at [sampleRate] — to the playback queue,
  /// opening the output on the first chunk. Resolves once the platform holds
  /// the chunk.
  ///
  /// Throws [XAudioSinkException] when the output cannot open.
  Future<void> enqueue(Int16List samples);

  /// Silences the output and empties the queue, including chunks enqueued but
  /// not yet handed to the platform. [state] settles to
  /// [XAudioSinkState.idle]; no [drained] event follows.
  Future<void> flush();
}

/// Production [XAudioSink]: `ux/audio_sink` for commands,
/// `ux/audio_sink/events` for drain and state.
class MethodChannelXAudioSink implements XAudioSink {
  /// Subscribes to the native event stream on platforms that register a
  /// handler for it.
  MethodChannelXAudioSink() {
    if (!supported) return;
    _events.receiveBroadcastStream().listen(_onEvent, onError: (e, st) {
      FlutterError.reportError(FlutterErrorDetails(
        exception: e,
        stack: st,
        library: 'ux',
        context: ErrorDescription('while playing audio'),
      ));
    });
  }

  static const _methods = MethodChannel('ux/audio_sink');
  static const _events = EventChannel('ux/audio_sink/events');

  /// Synchronous: a listener sees the drain in the turn the platform reports
  /// it, whatever zone the sink was constructed in.
  final _drained = StreamController<void>.broadcast(sync: true);
  Future<void>? _commandTail;

  /// Incremented by [flush]. A chunk enqueued under an older generation is
  /// dropped instead of reaching a queue the caller has already cancelled.
  int _generation = 0;

  @override
  bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.android);

  @override
  Stream<void> get drained => _drained.stream;

  @override
  final ValueEmitter<XAudioSinkState> state =
      ValueEmitter(XAudioSinkState.idle);

  @override
  Future<void> enqueue(Int16List samples) {
    final generation = _generation;
    return _enqueue(() async {
      if (!supported) {
        throw XAudioSinkException('unsupported', '$defaultTargetPlatform');
      }
      if (samples.isEmpty) return;
      if (generation != _generation) return;
      try {
        await _methods.invokeMethod<void>('enqueue', encodePcm(samples));
      } on PlatformException catch (e) {
        throw XAudioSinkException(e.code, e.message);
      }
    });
  }

  @override
  Future<void> flush() {
    _generation++;
    return _enqueue(() async {
      if (!supported) return;
      try {
        await _methods.invokeMethod<void>('flush');
      } on PlatformException catch (e) {
        throw XAudioSinkException(e.code, e.message);
      }
    });
  }

  /// Encodes [samples] as little-endian Int16, the byte order of every
  /// platform this plugin runs on.
  static Uint8List encodePcm(Int16List samples) {
    final bytes = Uint8List(samples.length * 2);
    final data = ByteData.view(bytes.buffer);
    for (var i = 0; i < samples.length; i++) {
      data.setInt16(i * 2, samples[i], Endian.little);
    }
    return bytes;
  }

  Future<void> _enqueue(Future<void> Function() command) {
    final previous = _commandTail;
    final operation =
        previous == null ? command() : previous.then((_) => command());
    final tail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    _commandTail = tail;
    tail.whenComplete(() {
      if (identical(_commandTail, tail)) _commandTail = null;
    });
    return operation;
  }

  void _onEvent(Object? event) {
    if (event is! Map) return;
    final m = event.cast<Object?, Object?>();
    switch (m['type']) {
      case 'drained':
        _drained.add(null);
      case 'state':
        final next = _parseState(m['state'] as String?);
        if (next != null) state.value = next;
    }
  }

  static XAudioSinkState? _parseState(String? raw) => switch (raw) {
        'idle' => XAudioSinkState.idle,
        'playing' => XAudioSinkState.playing,
        'interrupted' => XAudioSinkState.interrupted,
        _ => null,
      };
}
