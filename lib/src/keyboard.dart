import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

DynamicLibrary? _initLib() {
  if (Platform.isIOS) return DynamicLibrary.process();
  if (Platform.isAndroid) return DynamicLibrary.open('libux_keyboard.so');
  return null;
}

final DynamicLibrary? _lib = _initLib();

double Function()? _lookupDouble(String name) {
  if (_lib == null) return null;
  try {
    return _lib!.lookup<NativeFunction<Double Function()>>(name).asFunction<double Function()>();
  } catch (e) {
    return null;
  }
}

int Function()? _lookupInt32(String name) {
  if (_lib == null) return null;
  try {
    return _lib!.lookup<NativeFunction<Int32 Function()>>(name).asFunction<int Function()>();
  } catch (e) {
    return null;
  }
}

void Function()? _lookupVoid(String name) {
  if (_lib == null) return null;
  try {
    return _lib!.lookup<NativeFunction<Void Function()>>(name).asFunction<void Function()>();
  } catch (e) {
    return null;
  }
}

final _uxKeyboardHeight = _lookupDouble('ux_keyboard_height');
final _uxSystemHeight = _lookupDouble('ux_system_keyboard_height');
final _uxIsTracking = _lookupInt32('ux_is_tracking');
final _uxAnimTarget = _lookupDouble('ux_keyboard_anim_target');
final _uxAnimDuration = _lookupDouble('ux_keyboard_anim_duration');
final _uxAnimGen = _lookupInt32('ux_keyboard_anim_gen');

void Function(double)? _lookupEnableInteractiveDismiss() {
  if (_lib == null) return null;
  try {
    return _lib!
        .lookup<NativeFunction<Void Function(Double)>>('ux_enable_interactive_dismiss')
        .asFunction<void Function(double)>();
  } catch (e) {
    return null;
  }
}

final _uxEnableInteractiveDismiss = _lookupEnableInteractiveDismiss();
final _uxDisableInteractiveDismiss = _lookupVoid('ux_disable_interactive_dismiss');

/// iOS keyboard animation curve — sampled from native CADisplayLink.
/// 21 points at t = 0.00, 0.05, ..., 1.00. Averaged from multiple open/close cycles.
const _kIOSKeyboardSamples = <double>[
  0.0000, 0.0618, 0.1991, 0.3618, 0.5123, // t=0.00..0.20
  0.6375, 0.7362, 0.8112, 0.8664, 0.9062, // t=0.25..0.45
  0.9347, 0.9550, 0.9692, 0.9790, 0.9858, // t=0.50..0.70
  0.9904, 0.9935, 0.9956, 0.9971, 0.9980, // t=0.75..0.95
  0.9993, //                                  t=1.00
];

/// Android keyboard animation curve — sampled from WindowInsetsAnimation.onProgress.
/// 21 points at t = 0.00, 0.05, ..., 1.00. Averaged from multiple open/close cycles.
const _kAndroidKeyboardSamples = <double>[
  0.0000, 0.0056, 0.0702, 0.2332, 0.4147, // t=0.00..0.20
  0.5414, 0.6413, 0.7130, 0.7722, 0.8181, // t=0.25..0.45
  0.8576, 0.8885, 0.9146, 0.9372, 0.9538, // t=0.50..0.70
  0.9675, 0.9788, 0.9882, 0.9930, 0.9974, // t=0.75..0.95
  1.0000, //                                  t=1.00
];

/// Default head start — adaptive learning refines this from observations.
const _kDefaultHeadStart = 0.016;

/// EMA blending factor for adaptive updates.
const _kAdaptAlpha = 0.3;

/// Maximum error (in normalized progress) before the LUT is considered stale.
const _kAdaptThreshold = 0.02;

/// Number of clean animations required before updating.
const _kMinLearnCount = 2;

/// Number of LUT sample points (t = 0.00, 0.05, ..., 1.00).
const _kSampleCount = 21;

// ---------------------------------------------------------------------------

/// Linear interpolation through a list of evenly-spaced samples.
double _lerpSamples(List<double> samples, double t) {
  final n = samples.length - 1;
  final scaled = t * n;
  final i = scaled.floor().clamp(0, n - 1);
  final frac = scaled - i;
  return samples[i] + frac * (samples[i + 1] - samples[i]);
}

/// Inverse lookup: find the `t` where `_lerpSamples(samples, t) ≈ value`.
/// Assumes samples are monotonically increasing.
double _inverseLerp(List<double> samples, double value) {
  final n = samples.length - 1;
  if (value <= samples.first) return 0;
  if (value >= samples.last) return 1;
  for (int i = 0; i < n; i++) {
    if (value <= samples[i + 1]) {
      final span = samples[i + 1] - samples[i];
      final frac = span > 0 ? (value - samples[i]) / span : 0.0;
      return (i + frac) / n;
    }
  }
  return 1;
}

// ---------------------------------------------------------------------------

/// Frame-accurate keyboard height tracking for iOS and Android.
///
/// Reads the keyboard position directly from the native layer via FFI each
/// frame, bypassing Flutter's `MediaQuery.viewInsets` which lags behind.
///
/// Supports interactive dismiss (swipe-to-dismiss like iMessage) and provides
/// sampled native animation curves with adaptive learning.
///
/// Use the singleton [instance] and listen for changes via [addListener]:
///
/// ```dart
/// final keyboard = UxKeyboard.instance;
/// keyboard.enableInteractiveDismiss(trackingInset: 56);
/// ```
class UxKeyboard with ChangeNotifier {
  UxKeyboard._() {
    if (_lib == null) return;
    SchedulerBinding.instance.addPersistentFrameCallback(_onFrame);
  }

  /// The singleton instance.
  static final UxKeyboard instance = UxKeyboard._();

  double _height = 0;

  /// The current keyboard height in logical pixels.
  ///
  /// Updated every frame while the keyboard is animating or open.
  /// Returns 0 when the keyboard is fully closed.
  double get height => _height;

  /// The last system-reported keyboard height.
  ///
  /// Unlike [height], this is not interpolated — it reflects the target
  /// height from the most recent keyboard notification.
  double get systemHeight => _uxSystemHeight?.call() ?? 0;

  /// Whether the keyboard is currently visible.
  bool get isOpen => _height > 0;

  /// Whether an interactive dismiss pan gesture is active.
  ///
  /// When true, the user is dragging the keyboard down. Use this to freeze
  /// scroll views so they don't fight the pan gesture.
  bool get isTracking => (_uxIsTracking?.call() ?? 0) > 0;

  // Animation state — replays the keyboard's own animation inside Flutter.
  int _lastAnimGen = 0;
  double _animFrom = 0;
  double _animTo = 0;
  double _animDuration = 0;
  double _animStartTime = 0; // seconds, from frame timestamp
  bool _isAnimating = false;

  // Adaptive LUT state.
  late final List<double> _samples = List.of(
      Platform.isIOS ? _kIOSKeyboardSamples : _kAndroidKeyboardSamples);
  double _headStart = _kDefaultHeadStart;
  int _learnCount = 0;
  bool _converged = false;
  final List<({double t, double p})> _obs = [];

  void _onFrame(Duration timestamp) {
    if (_uxKeyboardHeight == null) return;

    final ts = timestamp.inMicroseconds / Duration.microsecondsPerSecond;

    // Detect new animation generation (both platforms).
    final gen = _uxAnimGen?.call() ?? 0;
    if (gen != _lastAnimGen) {
      _lastAnimGen = gen;
      final target = _uxAnimTarget?.call() ?? 0;
      final duration = _uxAnimDuration?.call() ?? 0;
      if (duration > 0) {
        _obs.clear(); // discard interrupted observations
        _animFrom = _height;
        _animTo = target;
        _animDuration = duration;
        _animStartTime = ts - _headStart;
        _isAnimating = true;
      } else {
        // Instant change (duration == 0) — snap immediately.
        _isAnimating = false;
        _height = target;
        notifyListeners();
      }
    }

    // Abort animation if interactive tracking started.
    if (_isAnimating && (_uxIsTracking?.call() ?? 0) > 0) {
      _isAnimating = false;
      _obs.clear();
    }

    double h;
    if (_isAnimating) {
      final elapsed = ts - _animStartTime;
      final t = (elapsed / _animDuration).clamp(0.0, 1.0);
      h = _animFrom + (_animTo - _animFrom) * _lerpSamples(_samples, t);

      // Collect observations for adaptive learning.
      if (t < 1.0 && !_converged) {
        final ffi = _uxKeyboardHeight!();
        final range = _animTo - _animFrom;
        if (range.abs() > 1) {
          final p = ((ffi - _animFrom) / range).clamp(0.0, 1.0);
          _obs.add((t: t, p: p));
        }
      }

      if (t >= 1.0) {
        h = _animTo;
        if (!Platform.isIOS) _isAnimating = false;
        _finishLearning();
      }
    } else {
      h = _uxKeyboardHeight!();
    }

    if ((h - _height).abs() > 0.5) {
      _height = h;
      notifyListeners();
    }

    // Schedule frames while the curve is still running.
    final curveActive = _isAnimating &&
        (ts - _animStartTime) < _animDuration;
    if (curveActive || (!Platform.isIOS && (h > 0 || _height > 0))) {
      SchedulerBinding.instance.scheduleFrame();
    }
  }

  /// After a clean animation, learn the head start and curve shape.
  void _finishLearning() {
    if (_converged || _obs.length < 10) {
      _obs.clear();
      return;
    }

    _learnCount++;
    if (_learnCount < _kMinLearnCount) {
      _obs.clear();
      return;
    }

    // Step 1: measure head start (δ) from the steep middle of the curve.
    final lags = <double>[];
    for (final o in _obs) {
      if (o.p < 0.15 || o.p > 0.85) continue;
      final lutT = _inverseLerp(_samples, o.p);
      lags.add(o.t - lutT);
    }
    if (lags.length >= 3) {
      lags.sort();
      final medianLag = lags[lags.length ~/ 2];
      final measuredHeadStart = medianLag * _animDuration;
      _headStart += _kAdaptAlpha * (measuredHeadStart - _headStart);
      _headStart = _headStart.clamp(0.0, 0.050); // sanity: 0–50ms
    }

    // Step 2: update curve shape — shift observations by δ, resample to grid.
    final delta = _headStart / _animDuration;
    final observed = List<double>.filled(_kSampleCount, -1);
    // Interpolate shifted observations onto the 21-point grid.
    final shifted = _obs
        .map((o) => (t: o.t - delta, p: o.p))
        .where((o) => o.t >= 0 && o.t <= 0.95)
        .toList()
      ..sort((a, b) => a.t.compareTo(b.t));

    if (shifted.length >= 5) {
      final step = 1.0 / (_kSampleCount - 1); // 0.05
      for (int i = 0; i < _kSampleCount; i++) {
        final gridT = i * step;
        if (gridT > 0.95) break;
        // Find bracketing observations.
        int lo = 0;
        while (lo < shifted.length - 1 && shifted[lo + 1].t <= gridT) {
          lo++;
        }
        if (lo >= shifted.length - 1) continue;
        final a = shifted[lo], b = shifted[lo + 1];
        final span = b.t - a.t;
        if (span < 0.001) continue;
        final frac = (gridT - a.t) / span;
        observed[i] = a.p + frac * (b.p - a.p);
      }

      // EMA blend where we have valid observations.
      double maxError = 0;
      for (int i = 1; i < _kSampleCount - 1; i++) {
        if (observed[i] < 0) continue;
        final error = (observed[i] - _samples[i]).abs();
        maxError = math.max(maxError, error);
        _samples[i] += _kAdaptAlpha * (observed[i] - _samples[i]);
      }
      // Endpoints stay pinned.
      _samples[0] = 0;
      _samples[_kSampleCount - 1] = _samples[_kSampleCount - 1]
          .clamp(0.99, 1.0);

      _converged = maxError < _kAdaptThreshold;

      if (kDebugMode) {
        print('[KB] adapt #$_learnCount headStart=${(_headStart * 1000).toStringAsFixed(1)}ms '
            'maxErr=${(maxError * 100).toStringAsFixed(1)}% '
            '${_converged ? "CONVERGED" : "learning"}');
      }
    }

    _obs.clear();
  }

  /// Enables swipe-to-dismiss on the keyboard.
  ///
  /// [trackingInset] is the height of your input bar in logical pixels.
  /// The dismiss gesture activates when the finger enters the keyboard zone
  /// below this inset.
  void enableInteractiveDismiss({double trackingInset = 0}) => _uxEnableInteractiveDismiss?.call(trackingInset);

  /// Disables the swipe-to-dismiss gesture.
  void disableInteractiveDismiss() => _uxDisableInteractiveDismiss?.call();
}
