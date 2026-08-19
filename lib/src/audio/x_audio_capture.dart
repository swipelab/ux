import 'dart:async';
import 'dart:math' as math;
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

/// One chunk of captured microphone audio: mono signed 16-bit PCM at
/// [XAudioCapture.sampleRate], with the RMS level of that chunk.
class XAudioFrame {
  /// Wraps [samples] and derives [level] from them.
  XAudioFrame(this.samples) : level = _rms(samples);

  /// Decodes a native frame — little-endian Int16, the byte order of every
  /// platform this plugin runs on.
  factory XAudioFrame.fromBytes(Uint8List bytes) {
    final data = ByteData.view(
      bytes.buffer,
      bytes.offsetInBytes,
      bytes.lengthInBytes,
    );
    final samples = Int16List(bytes.lengthInBytes ~/ 2);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = data.getInt16(i * 2, Endian.little);
    }
    return XAudioFrame(samples);
  }

  /// The PCM samples, one per mono sample slot.
  final Int16List samples;

  /// Root-mean-square amplitude over [samples], `0` (silence) to `1`
  /// (full scale). Computed in Dart so every platform reports the same
  /// number for the same audio.
  final double level;

  static double _rms(Int16List samples) {
    if (samples.isEmpty) return 0;
    var sum = 0.0;
    for (final sample in samples) {
      final v = sample / 32768.0;
      sum += v * v;
    }
    return math.sqrt(sum / samples.length);
  }
}

/// What an [XAudioSource] taps.
enum XAudioSourceKind {
  /// A hardware input: the built-in microphone, a headset, a USB interface.
  microphone,

  /// What the device itself plays.
  playback,
}

/// An input [XAudioCapture.start] can open, as the OS names it.
final class XAudioSource {
  /// Creates a source description.
  const XAudioSource({
    required this.id,
    required this.label,
    required this.kind,
  });

  /// Identifier handed back to [XAudioCapture.start].
  final String id;

  /// Name to show, from the platform.
  final String label;

  /// What [id] taps.
  final XAudioSourceKind kind;

  @override
  bool operator ==(Object other) =>
      other is XAudioSource &&
      other.id == id &&
      other.label == label &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(id, label, kind);

  @override
  String toString() => 'XAudioSource($id, $label, ${kind.name})';
}

/// Lifecycle of the tap.
enum XAudioCaptureState {
  /// Not capturing.
  idle,

  /// Delivering frames.
  running,

  /// The OS took the input away — a phone call, Siri, another app claiming
  /// the microphone, the input device disappearing, or the system ending a
  /// playback tap. Capture has stopped; the caller decides when to
  /// [XAudioCapture.start] again.
  interrupted,
}

/// Thrown by [XAudioCapture.start] when the tap cannot open, and by
/// [XAudioCapture.sources] when the platform reply breaks the wire contract.
///
/// [code] is one of `permission_denied`, `no_input_device`, `unknown_source`,
/// `start_failed`, `unsupported`, or the Dart-owned `invalid_response`, whose
/// [message] names the offending field.
class XAudioCaptureException implements Exception {
  /// Creates an exception with a wire [code] and an optional [message].
  const XAudioCaptureException(this.code, [this.message]);

  /// Machine-readable failure kind.
  final String code;

  /// Platform-supplied detail, when there is one.
  final String? message;

  @override
  String toString() => 'XAudioCaptureException($code, $message)';
}

/// Live PCM from a microphone or from what the device plays, tapped natively
/// and delivered to Dart as [XAudioFrame]s of mono 16 kHz Int16 samples.
///
/// The microphone tap is a *reader* of the input, not an owner of the capture
/// graph: Apple installs it on the `AVAudioEngine` input node, Android reads
/// an `AudioRecord` opened on `VOICE_COMMUNICATION`. Consumers feed it to
/// speech recognition and level meters.
///
/// ```dart
/// final capture = XAudioCapture.instance;
/// final sub = capture.frames.listen((f) => recognizer.add(f.samples));
/// await capture.start();
/// ```
///
/// [start] and [stop] are idempotent. [state] is the single source of truth
/// for whether frames are flowing — it drops to
/// [XAudioCaptureState.interrupted] when the OS revokes the input, and no
/// capture resumes on its own.
///
/// Android hosts must declare `android.permission.RECORD_AUDIO`; Apple hosts
/// need `NSMicrophoneUsageDescription`, and a sandboxed macOS host also needs
/// `com.apple.security.device.audio-input` and, for a playback tap,
/// `com.apple.security.screen-capture`. Capturing playback asks once more
/// at [start]: macOS through the screen-recording grant, Android through
/// the media-projection consent.
abstract interface class XAudioCapture {
  /// The process-wide tap. One source at a time, one instance.
  static final XAudioCapture instance = MethodChannelXAudioCapture();

  /// Sample rate of every delivered frame.
  static const int sampleRate = 16000;

  /// Samples per delivered frame — 20 ms at [sampleRate].
  static const int frameSamples = 320;

  /// Whether this platform has a native tap. Elsewhere [start] throws
  /// `unsupported` and [state] stays [XAudioCaptureState.idle].
  bool get supported;

  /// Captured audio, from [start] until capture stops. A broadcast stream:
  /// subscribing does not itself start capture.
  Stream<XAudioFrame> get frames;

  /// Current lifecycle state, driven by the native tap.
  ValueListenable<XAudioCaptureState> get state;

  /// What this host can tap right now: the hardware inputs the OS names,
  /// plus device playback where the platform taps it — macOS, and Android 10
  /// and newer. iOS lists microphones alone. Empty where [supported] is
  /// false.
  Future<List<XAudioSource>> sources();

  /// Opens [sourceId], or the system's default microphone when it is null,
  /// requesting permission if it has not been granted. Returns once frames
  /// are flowing; a second call while running does nothing, whatever
  /// [sourceId] it names.
  ///
  /// The default and an [XAudioSourceKind.microphone] id capture under the
  /// platform's voice processing, so what the device plays does not re-enter
  /// as local speech. An [XAudioSourceKind.playback] id taps that output
  /// instead, and runs without voice processing.
  ///
  /// Changing source is [stop] then [start]: one tap runs at a time and
  /// nothing is mixed.
  ///
  /// Throws [XAudioCaptureException] when the tap cannot open — `unknown_source`
  /// when [sourceId] names nothing [sources] lists.
  Future<void> start({String? sourceId});

  /// Closes the tap. Does nothing when already idle. [state] settles to
  /// [XAudioCaptureState.idle] behind the frames already in flight, so it
  /// can still read [XAudioCaptureState.running] as this returns.
  Future<void> stop();
}

/// Production [XAudioCapture]: `ux/audio_capture` for commands,
/// `ux/audio_capture/events` for frames and state.
class MethodChannelXAudioCapture implements XAudioCapture {
  /// Subscribes to the native event stream on platforms that register a
  /// handler for it.
  MethodChannelXAudioCapture() {
    if (!supported) return;
    _events.receiveBroadcastStream().listen(_onEvent, onError: (e, st) {
      FlutterError.reportError(FlutterErrorDetails(
        exception: e,
        stack: st,
        library: 'ux',
        context: ErrorDescription('while receiving microphone audio'),
      ));
    });
  }

  static const _methods = MethodChannel('ux/audio_capture');
  static const _events = EventChannel('ux/audio_capture/events');

  final _frames = StreamController<XAudioFrame>.broadcast();
  Future<void>? _commandTail;

  @override
  bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.android);

  @override
  Stream<XAudioFrame> get frames => _frames.stream;

  @override
  final ValueEmitter<XAudioCaptureState> state =
      ValueEmitter(XAudioCaptureState.idle);

  @override
  Future<List<XAudioSource>> sources() async {
    if (!supported) return const [];
    final List<Object?>? raw;
    try {
      raw = await _methods.invokeListMethod<Object?>('sources');
    } on PlatformException catch (e) {
      throw XAudioCaptureException(e.code, e.message);
    }
    if (raw == null) {
      throw const XAudioCaptureException('invalid_response', 'sources: null');
    }
    return raw.map(_decodeSource).toList(growable: false);
  }

  @override
  Future<void> start({String? sourceId}) => _enqueue(() async {
        if (!supported) {
          throw XAudioCaptureException('unsupported', '$defaultTargetPlatform');
        }
        try {
          await _methods.invokeMethod<void>(
            'start',
            sourceId == null ? null : {'sourceId': sourceId},
          );
        } on PlatformException catch (e) {
          throw XAudioCaptureException(e.code, e.message);
        }
      });

  @override
  Future<void> stop() => _enqueue(() async {
        if (!supported) return;
        try {
          await _methods.invokeMethod<void>('stop');
        } on PlatformException catch (e) {
          throw XAudioCaptureException(e.code, e.message);
        }
      });

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
      case 'frame':
        final pcm = m['pcm'];
        if (pcm is Uint8List) _frames.add(XAudioFrame.fromBytes(pcm));
      case 'state':
        final next = _parseState(m['state'] as String?);
        if (next != null) state.value = next;
    }
  }

  static XAudioSource _decodeSource(Object? raw) {
    if (raw is! Map) {
      throw XAudioCaptureException(
        'invalid_response',
        'source: expected a map, got ${raw.runtimeType}',
      );
    }
    final m = raw.cast<Object?, Object?>();
    final id = m['id'];
    final label = m['label'];
    final kind = _parseKind(m['kind']);
    if (id is! String || label is! String || kind == null) {
      throw XAudioCaptureException('invalid_response', 'source: $m');
    }
    return XAudioSource(id: id, label: label, kind: kind);
  }

  static XAudioSourceKind? _parseKind(Object? raw) => switch (raw) {
        'microphone' => XAudioSourceKind.microphone,
        'playback' => XAudioSourceKind.playback,
        _ => null,
      };

  static XAudioCaptureState? _parseState(String? raw) => switch (raw) {
        'idle' => XAudioCaptureState.idle,
        'running' => XAudioCaptureState.running,
        'interrupted' => XAudioCaptureState.interrupted,
        _ => null,
      };
}
