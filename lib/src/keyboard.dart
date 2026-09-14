import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:ux/src/_ffi.dart';
import 'package:ux/src/log.dart';

final _kbLog = Log.tag('KB');

final _uxKeyboardHeight = uxLookupDouble('ux_keyboard_height');
final _uxSystemHeight = uxLookupDouble('ux_system_keyboard_height');
final _uxIsTracking = uxLookupInt32('ux_is_tracking');
final _uxAnimTarget = uxLookupDouble('ux_keyboard_anim_target');
final _uxAnimDuration = uxLookupDouble('ux_keyboard_anim_duration');
final _uxAnimGen = uxLookupInt32('ux_keyboard_anim_gen');

final _uxEnableInteractiveDismiss = uxLookupVoidDouble('ux_enable_interactive_dismiss');
final _uxDisableInteractiveDismiss = uxLookupVoid('ux_disable_interactive_dismiss');
final _uxRegisterWake = uxLookupVoidCallback('ux_register_wake_callback');

void _uxKeyboardWake() {
  SchedulerBinding.instance.scheduleFrame();
}

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
/// final keyboard = XKeyboard.instance;
/// keyboard.enableInteractiveDismiss(trackingInset: 56);
/// ```
///
/// First access to [instance] registers a persistent frame callback and, on
/// Android, a method call handler — both require an initialized Flutter
/// binding, so touch it only after `runApp` (or an explicit
/// `WidgetsFlutterBinding.ensureInitialized()`).
class XKeyboard with ChangeNotifier, WidgetsBindingObserver {
  XKeyboard._()
      : _readHeight = _uxKeyboardHeight,
        _readIsTracking = _uxIsTracking,
        _readAnimTarget = _uxAnimTarget,
        _readAnimDuration = _uxAnimDuration,
        _readAnimGen = _uxAnimGen,
        _debugDevicePixelRatio = null {
    if (Platform.isAndroid) {
      _channel.setMethodCallHandler(_onMethodCall);
    }
    if (uxLib == null) return;
    WidgetsBinding.instance.addObserver(this);
    _uxRegisterWake?.call(
      Pointer.fromFunction<Void Function()>(_uxKeyboardWake),
    );
    SchedulerBinding.instance.addPersistentFrameCallback(_onFrame);
  }

  @override
  void didChangeMetrics() {
    SchedulerBinding.instance.scheduleFrame();
  }

  /// A keyboard with injected native readers — under `flutter test` the FFI
  /// symbols never resolve, so [instance] cannot exercise the frame loop.
  /// Registers no frame callback; drive it with [debugFrame].
  @visibleForTesting
  XKeyboard.test({
    required double Function() nativeHeight,
    int Function()? isTracking,
    double Function()? animTarget,
    double Function()? animDuration,
    int Function()? animGen,
    double devicePixelRatio = 1.0,
  })  : _readHeight = nativeHeight,
        _readIsTracking = isTracking,
        _readAnimTarget = animTarget,
        _readAnimDuration = animDuration,
        _readAnimGen = animGen,
        _debugDevicePixelRatio = devicePixelRatio;

  final double Function()? _readHeight;
  final int Function()? _readIsTracking;
  final double Function()? _readAnimTarget;
  final double Function()? _readAnimDuration;
  final int Function()? _readAnimGen;
  final double? _debugDevicePixelRatio;

  double get _devicePixelRatio =>
      _debugDevicePixelRatio ??
      SchedulerBinding
          .instance.platformDispatcher.implicitView?.devicePixelRatio ??
      1.0;

  /// Runs one frame of the reader loop.
  @visibleForTesting
  void debugFrame(Duration timestamp) => _onFrame(timestamp);

  /// The singleton instance.
  static final XKeyboard instance = XKeyboard._();

  static const _channel = MethodChannel('ux/keyboard');

  /// Increments each time the native window gains input focus — the signal
  /// Android needs before the IME can be raised. Listen for changes when you
  /// want to re-trigger a pending focus request at cold start (e.g. a
  /// `TextField(autofocus: true)` whose initial `TextInput.show` was dropped
  /// because the window wasn't yet focused).
  ///
  /// The value itself is a monotonically-increasing counter — only useful as a
  /// change signal, not as an absolute state.
  final windowFocusCounter = ValueNotifier<int>(0);

  Future<dynamic> _onMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onWindowFocused':
        windowFocusCounter.value++;
        break;
    }
  }

  double _height = 0;

  /// The current keyboard height in logical pixels, snapped to the physical
  /// pixel grid.
  ///
  /// Updated every frame while the keyboard is animating or open.
  /// Returns 0 when the keyboard is fully closed.
  double get height => _height;

  /// [h] on the physical-pixel grid of [devicePixelRatio]. Readings within
  /// the same physical pixel collapse to one published value, so listeners
  /// never see sub-pixel churn.
  @visibleForTesting
  static double snapToPixelGrid(double h, double devicePixelRatio) =>
      devicePixelRatio > 0
          ? (h * devicePixelRatio).roundToDouble() / devicePixelRatio
          : h;

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
  bool get isTracking => (_readIsTracking?.call() ?? 0) > 0;

  // Animation state — replays the keyboard's own animation inside Flutter.
  int _lastAnimGen = 0;
  double _animFrom = 0;
  double _animTo = 0;
  double _animDuration = 0;
  double _animStartTime = 0; // seconds, from frame timestamp
  bool _isAnimating = false;

  /// Caps idle and tracking readings at the announced target — the presented
  /// frame can rest a fraction of a point above it, and that excess must not
  /// publish. An announced close clears it: a close settles on the native
  /// reading.
  double? _restCeiling;

  // Adaptive LUT state.
  late final List<double> _samples = List.of(
      Platform.isIOS ? _kIOSKeyboardSamples : _kAndroidKeyboardSamples);
  double _headStart = _kDefaultHeadStart;
  int _learnCount = 0;
  bool _converged = false;
  final List<({double t, double p})> _obs = [];

  void _onFrame(Duration timestamp) {
    if (_readHeight == null) return;

    final ts = timestamp.inMicroseconds / Duration.microsecondsPerSecond;

    // Detect new animation generation (both platforms).
    final gen = _readAnimGen?.call() ?? 0;
    if (gen != _lastAnimGen) {
      _lastAnimGen = gen;
      final target = _readAnimTarget?.call() ?? 0;
      final duration = _readAnimDuration?.call() ?? 0;
      _restCeiling = target < _height ? null : target;
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
        _height = snapToPixelGrid(target, _devicePixelRatio);
        notifyListeners();
      }
    }

    // Abort animation if interactive tracking started.
    if (_isAnimating && (_readIsTracking?.call() ?? 0) > 0) {
      _isAnimating = false;
      _obs.clear();
    }

    double h;
    if (_isAnimating) {
      final elapsed = ts - _animStartTime;
      final t = (elapsed / _animDuration).clamp(0.0, 1.0);
      h = _animFrom + (_animTo - _animFrom) * _lerpSamples(_samples, t);

      final native = _readHeight();
      h = clampPrediction(
        h: h,
        native: native,
        animFrom: _animFrom,
        animTo: _animTo,
        current: _height,
      );

      // Collect observations for adaptive learning.
      if (t < 1.0 && !_converged) {
        final range = _animTo - _animFrom;
        if (range.abs() > 1) {
          final p = ((native - _animFrom) / range).clamp(0.0, 1.0);
          _obs.add((t: t, p: p));
        }
      }

      if (t >= 1.0) {
        if (_animTo < _animFrom) {
          // A close settles on the native reading — the real keyboard can
          // lag the announced duration.
          h = native;
        } else {
          h = _animTo;
          _restCeiling = _animTo;
        }
        _isAnimating = false;
        _finishLearning();
      }
    } else {
      h = _readHeight();
      final ceiling = _restCeiling;
      if (ceiling != null && h > ceiling) {
        // Sub-pixel native excess around the settled target. A jump of
        // more than 1pt is a real IME resize.
        if (h - ceiling <= 1) {
          h = ceiling;
        } else {
          _restCeiling = h;
        }
      }
    }

    final snapped = snapToPixelGrid(h, _devicePixelRatio);
    if (snapped != _height) {
      _height = snapped;
      notifyListeners();
      // Close-edge flush: when _height transitions to 0, the steady-state
      // pump below (h>0 || _height>0) stops scheduling, and
      // ensureVisualUpdate is a no-op inside a persistent frame callback —
      // so dirty marks enqueued during notifyListeners would never get
      // flushed. Mid-animation transitions don't need this because the
      // pump or curveActive condition already covers them.
      if (_height == 0) {
        SchedulerBinding.instance.scheduleFrame();
      }
    }

    // Schedule frames while the curve is still running, and while the
    // keyboard is up so a late native height is not missed after idle.
    final curveActive = _isAnimating &&
        (ts - _animStartTime) < _animDuration;
    if (curveActive || h > 0 || _height > 0) {
      SchedulerBinding.instance.scheduleFrame();
    }
  }

  /// Caps the LUT prediction [h] against the fresh [native] reading. The
  /// native value is per-vsync fresh on Android R+ (via
  /// WindowInsetsAnimation.onProgress) and iOS (via CADisplayLink); on
  /// Android pre-R it snaps to the target up-front, making this a no-op.
  /// This trades the LUT's predictive *lead* for robustness against
  /// overshoot when the LUT hasn't adapted to this device's actual curve.
  ///
  /// Rising ([animTo] > [animFrom]): native is a ceiling the prediction may
  /// not overshoot. Closing: native is a floor that can hold the height up
  /// while the real keyboard lags, but never raise it — the floor is trusted
  /// only inside `[animTo, animFrom]` and never above [current], so a native
  /// flash back to the full frame mid-close cannot lift the height.
  @visibleForTesting
  static double clampPrediction({
    required double h,
    required double native,
    required double animFrom,
    required double animTo,
    required double current,
  }) {
    if (animTo > animFrom && h > native) {
      return native;
    }
    if (animTo < animFrom && h < native) {
      final floor = math.min(clampDouble(native, animTo, animFrom), current);
      return math.max(h, floor);
    }
    return h;
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

      _kbLog.d(
        () => 'adapt #$_learnCount '
            'headStart=${(_headStart * 1000).toStringAsFixed(1)}ms '
            'maxErr=${(maxError * 100).toStringAsFixed(1)}% '
            '${_converged ? "CONVERGED" : "learning"}',
      );
    }

    _obs.clear();
  }

  /// Enables swipe-to-dismiss on the keyboard.
  ///
  /// [trackingInset] is the height of your input bar in logical pixels.
  /// On iOS a downward drag from the chat window (stream or composer)
  /// starts tracking. Velocity at lift-off commits dismiss or snap-back.
  /// A matching pan on the keyboard host view starts on a downward swipe
  /// on the IME itself.
  void enableInteractiveDismiss({double trackingInset = 0}) => _uxEnableInteractiveDismiss?.call(trackingInset);

  /// Disables the swipe-to-dismiss gesture.
  void disableInteractiveDismiss() => _uxDisableInteractiveDismiss?.call();
}
