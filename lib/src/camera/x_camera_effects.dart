import 'package:flutter/foundation.dart' show ValueListenable;

import 'package:ux/src/camera/x_camera_effects_channel.dart'
    show MethodChannelXCameraEffectsBackend;

/// What the outgoing camera track carries behind the person.
enum XCameraEffect {
  /// The camera's own frames, untouched.
  none,

  /// A blurred background.
  blur,

  /// A darkened background.
  dim,
}

/// How far an effect has got.
enum XCameraEffectPhase {
  /// No effect is applied.
  idle,

  /// The platform accepted the effect; effected frames are not flowing yet.
  applying,

  /// Every frame leaving the track carries the effect.
  active,

  /// Processing stopped after the effect was active.
  failed,
}

/// The effect on the track and the phase it is in.
final class XCameraEffectStatus {
  /// Creates a status.
  const XCameraEffectStatus({
    required this.phase,
    required this.effect,
    this.code,
  }) : assert(code == null || phase == XCameraEffectPhase.failed),
       assert(phase != XCameraEffectPhase.idle || effect == XCameraEffect.none);

  /// Nothing applied, nothing pending.
  const XCameraEffectStatus.idle()
    : phase = XCameraEffectPhase.idle,
      effect = XCameraEffect.none,
      code = null;

  /// How far [effect] has got.
  final XCameraEffectPhase phase;

  /// The effect this status describes; [XCameraEffect.none] while idle.
  final XCameraEffect effect;

  /// Why processing stopped, set only with [XCameraEffectPhase.failed]:
  /// `processing_failed` for a fault after activation,
  /// `integration_unavailable` when the bridge disappears under a live
  /// attachment. A command that fails throws instead of reporting here.
  final String? code;

  @override
  bool operator ==(Object other) =>
      other is XCameraEffectStatus &&
      other.phase == phase &&
      other.effect == effect &&
      other.code == code;

  @override
  int get hashCode => Object.hash(phase, effect, code);

  @override
  String toString() => 'XCameraEffectStatus($phase, $effect, $code)';
}

/// Thrown by [XCameraEffectsBackend] when a command cannot be served.
///
/// [code] is the platform's own — `unsupported`, `integration_unavailable`,
/// `track_not_found`, `track_not_processable`, `initialization_failed` — or
/// the Dart-owned `invalid_response`, whose [message] names the offending
/// field.
class XCameraEffectsException implements Exception {
  /// Creates an exception with a wire [code] and an optional [message].
  const XCameraEffectsException(this.code, [this.message]);

  /// Machine-readable failure kind.
  final String code;

  /// Platform-supplied detail, when there is one.
  final String? message;

  @override
  String toString() => 'XCameraEffectsException($code, $message)';
}

/// None / Blur / Dim on the outgoing camera track, applied natively on the
/// frames the call already publishes.
///
/// ```dart
/// final effects = XCameraEffectsBackend.instance;
/// if (await effects.available()) {
///   await effects.setEffect(trackId, XCameraEffect.blur);
/// }
/// ```
///
/// One track carries an effect at a time, so [clear] names no track: it
/// releases whichever one [setEffect] named last. Commands serialize, and one
/// that fails leaves the next callable.
///
/// A command reports its own outcome by returning or throwing; [status] is the
/// native processor's, and it is what reports a fault that arrives after a
/// command has succeeded.
abstract interface class XCameraEffectsBackend {
  /// The process-wide backend. Swap to inject a fake before any effect code
  /// runs.
  static XCameraEffectsBackend instance = MethodChannelXCameraEffectsBackend();

  /// Whether this platform family has a native processor. Elsewhere every
  /// method throws [XCameraEffectsException] with code `unsupported`.
  bool get supported;

  /// Whether this host can effect frames — the OS version, the GPU profile and
  /// the installed bridge as well as the platform family.
  Future<bool> available();

  /// What the native processor is delivering right now, starting at
  /// [XCameraEffectStatus.idle].
  ValueListenable<XCameraEffectStatus> get status;

  /// Applies [effect] to the local video track [trackId], releasing whichever
  /// track was effected before.
  ///
  /// Returns once the platform has taken the command; [status] reaches
  /// [XCameraEffectPhase.active] when effected frames flow. [XCameraEffect.none]
  /// is [clear].
  Future<void> setEffect(String trackId, XCameraEffect effect);

  /// Returns the effected track to its own frames, leaving [status] idle.
  Future<void> clear();
}
