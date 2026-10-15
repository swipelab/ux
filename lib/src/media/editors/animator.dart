import 'dart:async';
import 'dart:math' as math;

import 'package:ux/src/media/design.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:ux/ux.dart';

/// Settle duration paired with [TgSpringCurve] — the spring's amplitude
/// decays below 0.2% inside this window.
const Duration kTgSpring = Duration(milliseconds: 460);

/// Damped-spring curve equal to telegram's POP springs (`springSpeed 7,
/// springBounciness 1` → tension ≈285, friction ≈29, mass 1 — barely
/// underdamped, ζ ≈ 0.86). Normalized to reach 1.0 at t = 1 over
/// [kTgSpring].
class TgSpringCurve extends Curve {
  /// Creates the curve.
  const TgSpringCurve();

  static const double _omega = 16.88;
  static const double _zeta = 0.859;

  @override
  double transformInternal(double t) {
    final seconds = t * kTgSpring.inMilliseconds / 1000;
    final decay = _zeta * _omega;
    final omegaD = _omega * math.sqrt(1 - _zeta * _zeta);
    final envelope = math.exp(-decay * seconds);
    return 1 -
        envelope *
            (math.cos(omegaD * seconds) +
                decay / omegaD * math.sin(omegaD * seconds));
  }
}

/// Tween-driving animator with cancel-and-replace semantics.
///
/// [T] must support `+`, `-`, and `*` (scalar multiply by `double`). A
/// [Ticker] drives the interpolation off frame-presentation time
/// (same model as `CALayer.animate(...)` on iOS) between the current
/// value (read via [getter]) and a target.
///
/// A new [animate] cancels any in-flight tween. Caller awaits the returned
/// future to know when the animation either completed or was superseded.
class Animator<T> with Dispose {
  /// Animates the value read by [getter] and written by [setter], along
  /// [curve] unless [animate] names another.
  Animator({required this.getter, required this.setter, this.curve}) {
    _CancelDisposer(cancel).disposeBy(this);
  }

  /// Convenience: wrap a [ValueEmitter] so its `value` is the animated state.
  static Animator<T> emitter<T>(ValueEmitter<T> emitter, {Curve? curve}) =>
      Animator<T>(
        getter: () => emitter.value,
        setter: (e) => emitter.value = e,
        curve: curve,
      );

  /// Reads the animated value.
  final ValueGetter<T> getter;

  /// Writes the animated value.
  final ValueSetter<T> setter;

  /// The curve of an [animate] that names none; linear when absent.
  final Curve? curve;

  Completer<void>? _completer;
  Ticker? _ticker;

  /// Whether a tween is running.
  bool get isAnimating => _ticker?.isActive == true;

  /// Stops the tween in flight and completes its future.
  void cancel() {
    final ticker = _ticker;
    _ticker = null;
    ticker?.dispose();
    final completer = _completer;
    _completer = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  /// Animate the current value (read via [getter]) toward [target] over
  /// [duration]. Returns a future that completes when the animation
  /// finishes — or when a subsequent [animate] supersedes it.
  Future<void> animate({
    required T target,
    Duration duration = kAnimation,
    Curve? curve,
  }) {
    final currentValue = getter();
    if (currentValue == target) return Future<void>.value();

    cancel();

    final dynamic start = currentValue;
    final dynamic difference = (target as dynamic) - start;
    final completer = _completer = Completer<void>();
    final c = curve ?? this.curve ?? Curves.linear;

    _ticker = Ticker((elapsed) {
      if (disposed) {
        cancel();
        return;
      }
      if (elapsed >= duration) {
        setter(target);
        cancel();
        return;
      }
      final progress = elapsed.inMicroseconds / duration.inMicroseconds;
      final curved = c.transform(progress.clamp(0.0, 1.0));
      setter((start + difference * curved) as T);
    })..start();

    return completer.future;
  }
}

class _CancelDisposer with Dispose {
  _CancelDisposer(this._cancel);
  final VoidCallback _cancel;

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }
}
