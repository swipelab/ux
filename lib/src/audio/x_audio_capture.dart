import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, ValueListenable, defaultTargetPlatform;
import 'package:flutter/services.dart';

import 'package:ux/src/core/emitter.dart';
import 'package:ux/src/log.dart' show Log;

final _log = Log.tag('audio_capture');

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

/// Lifecycle of the microphone tap.
enum XAudioCaptureState {
  /// Not capturing.
  idle,

  /// Delivering frames.
  running,

  /// The OS took the microphone away — a phone call, Siri, another app
  /// claiming the input, or the input device disappearing. Capture has
  /// stopped; the caller decides when to [XAudioCapture.start] again.
  interrupted,
}

/// Thrown by [XAudioCapture.start] when the tap cannot open.
///
/// [code] is one of `permission_denied`, `no_input_device`, `start_failed`,
/// or `unsupported`.
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

/// Live microphone PCM, tapped natively and delivered to Dart as
/// [XAudioFrame]s of mono 16 kHz Int16 samples.
///
/// The tap is a *reader* of the input, not an owner of the capture graph:
/// Apple installs it on the `AVAudioEngine` input node, Android reads an
/// `AudioRecord` opened on `VOICE_RECOGNITION`. Consumers feed it to speech
/// recognition and level meters.
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
/// the `com.apple.security.device.audio-input` entitlement.
abstract interface class XAudioCapture {
  /// The process-wide tap. One microphone, one instance.
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

  /// Opens the microphone, requesting permission if it has not been granted.
  /// Returns once frames are flowing; a second call while running does
  /// nothing.
  ///
  /// Throws [XAudioCaptureException] when the tap cannot open.
  Future<void> start();

  /// Closes the microphone. Does nothing when already idle. [state] settles
  /// to [XAudioCaptureState.idle] behind the frames already in flight, so it
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
      _log.w('event channel error', error: e, stackTrace: st);
    });
  }

  static const _methods = MethodChannel('ux/audio_capture');
  static const _events = EventChannel('ux/audio_capture/events');

  final _frames = StreamController<XAudioFrame>.broadcast();

  @override
  bool get supported =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.android;

  @override
  Stream<XAudioFrame> get frames => _frames.stream;

  @override
  final ValueEmitter<XAudioCaptureState> state =
      ValueEmitter(XAudioCaptureState.idle);

  @override
  Future<void> start() async {
    if (!supported) {
      throw XAudioCaptureException('unsupported', '$defaultTargetPlatform');
    }
    try {
      await _methods.invokeMethod<void>('start');
    } on PlatformException catch (e) {
      throw XAudioCaptureException(e.code, e.message);
    }
  }

  @override
  Future<void> stop() async {
    if (!supported) return;
    try {
      await _methods.invokeMethod<void>('stop');
    } on PlatformException catch (e) {
      throw XAudioCaptureException(e.code, e.message);
    }
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

  static XAudioCaptureState? _parseState(String? raw) => switch (raw) {
        'idle' => XAudioCaptureState.idle,
        'running' => XAudioCaptureState.running,
        'interrupted' => XAudioCaptureState.interrupted,
        _ => null,
      };
}
