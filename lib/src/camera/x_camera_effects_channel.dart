import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, ValueListenable, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart';

import 'package:ux/src/camera/x_camera_effects.dart';
import 'package:ux/src/core/emitter.dart';

/// Production [XCameraEffectsBackend]: `ux/camera_effects` for commands,
/// `ux/camera_effects/events` for status.
///
/// The status stream is subscribed to on the first wire call that succeeds,
/// which is also what proves a native handler is registered; the native side
/// answers that activation with the current status, stamped with the last
/// generation Dart sent it.
class MethodChannelXCameraEffectsBackend implements XCameraEffectsBackend {
  /// Creates a backend bound to the `ux/camera_effects` channels.
  MethodChannelXCameraEffectsBackend();

  static const _methods = MethodChannel('ux/camera_effects');
  static const _events = EventChannel('ux/camera_effects/events');

  final ValueEmitter<XCameraEffectStatus> _status =
      ValueEmitter(const XCameraEffectStatus.idle());

  Future<void>? _commandTail;
  StreamSubscription<Object?>? _subscription;
  int _allocated = 0;

  /// The generation of the last command the platform took; status stamped
  /// below it describes a retired effect.
  int _live = 0;

  @override
  bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  @override
  ValueListenable<XCameraEffectStatus> get status => _status;

  @override
  Future<bool> available() async {
    _requireSupported();
    final result = await _invoke('available');
    if (result is! bool) {
      throw _invalid('result', 'expected bool, got ${result.runtimeType}');
    }
    if (result) _subscribe();
    return result;
  }

  @override
  Future<void> setEffect(String trackId, XCameraEffect effect) =>
      effect == XCameraEffect.none
          ? clear()
          : _command(
              'setEffect',
              (generation) => {
                'trackId': trackId,
                'effect': effect.name,
                'generation': generation,
              },
            );

  @override
  Future<void> clear() => _command(
        'clear',
        (generation) => {'generation': generation},
        settled: const XCameraEffectStatus.idle(),
      );

  Future<void> _command(
    String method,
    Map<String, Object?> Function(int generation) arguments, {
    XCameraEffectStatus? settled,
  }) =>
      _serialize(() async {
        _requireSupported();
        final generation = ++_allocated;
        await _invoke(method, arguments(generation));
        _live = generation;
        if (settled != null) _status.value = settled;
        _subscribe();
      });

  Future<void> _serialize(Future<void> Function() command) {
    final previous = _commandTail;
    final operation =
        previous == null ? command() : previous.then((_) => command());
    final tail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _commandTail = tail;
    tail.whenComplete(() {
      if (identical(_commandTail, tail)) _commandTail = null;
    });
    return operation;
  }

  Future<Object?> _invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      return await _methods.invokeMethod<Object?>(method, arguments);
    } on MissingPluginException catch (e) {
      throw XCameraEffectsException('integration_unavailable', e.message);
    } on PlatformException catch (e) {
      throw XCameraEffectsException(e.code, e.message);
    }
  }

  void _subscribe() {
    _subscription ??= _events.receiveBroadcastStream().listen(
          _onEvent,
          onError: (Object _, StackTrace _) {},
        );
  }

  void _onEvent(Object? event) {
    if (event is! Map) return;
    final m = event.cast<Object?, Object?>();
    final generation = m['generation'];
    if (generation is! int || generation < _live) return;
    final phase = _phase(m['phase']);
    final effect = _effect(m['effect']);
    final code = m['code'];
    if (phase == null || effect == null || code is! String?) return;
    if (code != null && phase != XCameraEffectPhase.failed) return;
    if (phase == XCameraEffectPhase.idle && effect != XCameraEffect.none) {
      return;
    }
    _status.value =
        XCameraEffectStatus(phase: phase, effect: effect, code: code);
  }

  void _requireSupported() {
    if (supported) return;
    throw XCameraEffectsException('unsupported', '$defaultTargetPlatform');
  }

  static XCameraEffectPhase? _phase(Object? raw) => switch (raw) {
        'idle' => XCameraEffectPhase.idle,
        'applying' => XCameraEffectPhase.applying,
        'active' => XCameraEffectPhase.active,
        'failed' => XCameraEffectPhase.failed,
        _ => null,
      };

  static XCameraEffect? _effect(Object? raw) => switch (raw) {
        'none' => XCameraEffect.none,
        'blur' => XCameraEffect.blur,
        'dim' => XCameraEffect.dim,
        _ => null,
      };

  static XCameraEffectsException _invalid(Object? field, String detail) =>
      XCameraEffectsException('invalid_response', '$field: $detail');
}
