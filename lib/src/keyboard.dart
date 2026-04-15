import 'dart:ffi';
import 'dart:io';

import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

final bool _isIOS = Platform.isIOS;

DynamicLibrary? _initLib() {
  if (!_isIOS) return null;
  return DynamicLibrary.process();
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
const _kKeyboardSamples = <double>[
  0.0000, 0.0618, 0.1991, 0.3618, 0.5123, // t=0.00..0.20
  0.6375, 0.7362, 0.8112, 0.8664, 0.9062, // t=0.25..0.45
  0.9347, 0.9550, 0.9692, 0.9790, 0.9858, // t=0.50..0.70
  0.9904, 0.9935, 0.9956, 0.9971, 0.9980, // t=0.75..0.95
  0.9993, //                                  t=1.00
];

const Curve _kKeyboardCurve = _SampledCurve(_kKeyboardSamples);

class _SampledCurve extends Curve {
  const _SampledCurve(this._samples);
  final List<double> _samples;

  @override
  double transformInternal(double t) {
    final n = _samples.length - 1;
    final scaled = t * n;
    final i = scaled.floor().clamp(0, n - 1);
    final frac = scaled - i;
    return _samples[i] + frac * (_samples[i + 1] - _samples[i]);
  }
}

class UxKeyboard with ChangeNotifier {
  UxKeyboard._() {
    if (!_isIOS) return;
    SchedulerBinding.instance.addPersistentFrameCallback(_onFrame);
  }

  static final UxKeyboard instance = UxKeyboard._();

  double _height = 0;

  double get height => _height;
  double get systemHeight => _uxSystemHeight?.call() ?? 0;
  bool get isOpen => _height > 0;
  bool get isTracking => (_uxIsTracking?.call() ?? 0) > 0;

  // Animation state — replays the keyboard's own animation inside Flutter.
  int _lastAnimGen = 0;
  double _animFrom = 0;
  double _animTo = 0;
  double _animDuration = 0;
  double _animStartTime = 0; // seconds, from frame timestamp
  bool _isAnimating = false;

  void _onFrame(Duration timestamp) {
    if (_uxKeyboardHeight == null) return;

    final ts = timestamp.inMicroseconds / Duration.microsecondsPerSecond;

    // Detect new keyboard animation from native
    final gen = _uxAnimGen?.call() ?? 0;
    if (gen != _lastAnimGen) {
      _lastAnimGen = gen;
      final target = _uxAnimTarget?.call() ?? 0;
      final duration = _uxAnimDuration?.call() ?? 0;
      if (duration > 0) {
        _animFrom = _height;
        _animTo = target;
        _animDuration = duration - 0.01; // finish 10ms ahead of native
        _animStartTime = ts - 0.016; // compensate 2-frame pipeline delay
        _isAnimating = true;
      }
    }

    // Abort animation if interactive tracking started
    if (_isAnimating && (_uxIsTracking?.call() ?? 0) > 0) {
      _isAnimating = false;
    }

    double h;
    if (_isAnimating) {
      final elapsed = ts - _animStartTime;
      final t = (elapsed / _animDuration).clamp(0.0, 1.0);
      h = _animFrom + (_animTo - _animFrom) * _kKeyboardCurve.transform(t);
      if (t >= 1.0) {
        _isAnimating = false;
        h = _animTo;
      }
    } else {
      // Fallback: read FFI directly (interactive dismiss, snap-back, etc.)
      h = _uxKeyboardHeight!();
    }

    if ((h - _height).abs() > 0.5) {
      _height = h;
      notifyListeners();
    }

    if (_isAnimating) {
      SchedulerBinding.instance.scheduleFrame();
    }
  }

  void enableInteractiveDismiss({double trackingInset = 0}) => _uxEnableInteractiveDismiss?.call(trackingInset);
  void disableInteractiveDismiss() => _uxDisableInteractiveDismiss?.call();
}
