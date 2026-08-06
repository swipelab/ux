import 'package:ux/src/camera/x_camera_effects.dart';
import 'package:ux/src/core/emitter.dart';

/// One recorded [FakeXCameraEffectsBackend] call: the method, and the
/// arguments the caller passed it.
typedef FakeCameraEffectsCall = ({
  String method,
  String? trackId,
  XCameraEffect? effect,
});

/// In-memory backend for camera-effect tests. Swap in via
/// `XCameraEffectsBackend.instance = FakeXCameraEffectsBackend()` before any
/// effect code runs; restore with `XCameraEffectsBackend.instance =
/// MethodChannelXCameraEffectsBackend()` in `tearDown`.
///
/// Records every call and answers with scripted results: set the `…Error`
/// fields to drive a consumer's failure paths, and assign [status] to play the
/// phases it reacts to.
class FakeXCameraEffectsBackend implements XCameraEffectsBackend {
  /// Creates a fake that starts out supported, available and idle.
  FakeXCameraEffectsBackend({
    this.supported = true,
    this.availableResult = true,
  });

  /// Every call, in order, with the arguments it was given.
  final List<FakeCameraEffectsCall> calls = [];

  @override
  bool supported;

  /// Result of [available].
  bool availableResult;

  /// If non-null, thrown by [available].
  XCameraEffectsException? availableError;

  /// If non-null, thrown by [setEffect].
  XCameraEffectsException? setEffectError;

  /// If non-null, thrown by [clear].
  XCameraEffectsException? clearError;

  /// What a consumer observes; assign to it to drive the phases.
  @override
  final ValueEmitter<XCameraEffectStatus> status =
      ValueEmitter(const XCameraEffectStatus.idle());

  @override
  Future<bool> available() async {
    _requireSupported();
    calls.add((method: 'available', trackId: null, effect: null));
    final error = availableError;
    if (error != null) throw error;
    return availableResult;
  }

  @override
  Future<void> setEffect(String trackId, XCameraEffect effect) async {
    _requireSupported();
    calls.add((method: 'setEffect', trackId: trackId, effect: effect));
    final error = setEffectError;
    if (error != null) throw error;
  }

  @override
  Future<void> clear() async {
    _requireSupported();
    calls.add((method: 'clear', trackId: null, effect: null));
    final error = clearError;
    if (error != null) throw error;
  }

  void _requireSupported() {
    if (supported) return;
    throw const XCameraEffectsException('unsupported', 'fake');
  }
}
