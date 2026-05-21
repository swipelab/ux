import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// A [Chrono] is a [Timer] which only runs while the app is _resumed_.
///
/// When the app is in the background, the [Chrono] stops ticking, and when
/// the app is resumed it restarts taking into account how much time
/// already elapsed in background. Uses a [WidgetsBindingObserver] to
/// react to App Lifecycle changes.
abstract class Chrono with WidgetsBindingObserver implements Timer {
  /// One-shot variant. Fires [callback] once after [duration] of resumed time.
  factory Chrono(
    Duration duration,
    VoidCallback callback, [
    /// in case we have a faster way to subscribe to WidgetsBinding.instance.addObserver
    ValueListenable<AppLifecycleState>? appLifecycle,
  ]) =>
      _ScheduledTimer(duration, callback, appLifecycle);

  /// Periodic variant. Fires [callback] every [interval] of resumed time.
  factory Chrono.periodic(
    Duration interval,
    void Function(Timer) callback, {
    bool fireOnStart = false,

    /// in case we have a faster way to subscribe to WidgetsBinding.instance.addObserver
    ValueListenable<AppLifecycleState>? appLifecycle,
  }) =>
      _PeriodicTimer(interval, callback, fireOnStart, appLifecycle);

  Chrono._([this._appLifecycle]) {
    if (_appLifecycle == null) {
      WidgetsBinding.instance.addObserver(this);
    } else {
      _appLifecycle!.addListener(_appLifecycleStateChanged);
    }
    stopwatch.start();
  }

  bool _isPaused =
      WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;

  Timer? _timer;
  bool _isCancelled = false;

  /// Tracks how much resumed time has elapsed since construction (or
  /// since the last periodic fire), used to compute the remaining
  /// duration on resume.
  final Stopwatch stopwatch = clock.stopwatch();

  @override
  bool get isActive => !(_isCancelled || _isPaused);

  @override
  int get tick => _timer?.tick ?? 0;

  final ValueListenable<AppLifecycleState>? _appLifecycle;

  void _appLifecycleStateChanged([AppLifecycleState? state]) {
    state = state ?? _appLifecycle?.value;
    if (state == AppLifecycleState.resumed) {
      if (_isPaused) {
        _isPaused = false;
        resume();
      }
    } else {
      if (!_isPaused) {
        _isPaused = true;
        pause();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _appLifecycleStateChanged(state);

  /// Cancels the underlying [Timer] when the app backgrounds. Subclasses
  /// extend this if they need additional pause-time bookkeeping.
  @mustCallSuper
  void pause() {
    _timer?.cancel();
    _timer = null;
  }

  /// Re-arms the underlying [Timer] for the remaining duration when the
  /// app foregrounds again.
  void resume();

  @override
  @mustCallSuper
  void cancel() {
    if (_appLifecycle == null) {
      WidgetsBinding.instance.removeObserver(this);
    } else {
      _appLifecycle!.removeListener(_appLifecycleStateChanged);
    }
    _isCancelled = true;
    _timer?.cancel();
    _timer = null;
  }
}

class _ScheduledTimer extends Chrono {
  _ScheduledTimer(this.duration, this.callback, super.appLifecycle)
      : super._() {
    if (isActive) {
      _timer = Timer(duration, execute);
    }
  }

  final Duration duration;
  final VoidCallback callback;

  @override
  void resume() {
    _timer = Timer(duration - stopwatch.elapsed, execute);
  }

  void execute() {
    cancel();
    callback();
  }
}

class _PeriodicTimer extends Chrono {
  _PeriodicTimer(
    this.interval,
    this.callback,
    bool fireOnStart,
    super.appLifecycle,
  ) : super._() {
    if (isActive && fireOnStart) {
      execute(this);
    }
    setupPeriodic();
  }

  final Duration interval;
  final void Function(Timer timer) callback;

  void setupPeriodic() {
    if (isActive) {
      _timer = Timer.periodic(interval, execute);
    }
  }

  @override
  void resume() {
    _timer = Timer(interval - stopwatch.elapsed, firstExecuteAfterResume);
  }

  void firstExecuteAfterResume() {
    stopwatch.reset();
    _timer?.cancel();
    setupPeriodic();
    callback(this);
  }

  void execute(Timer timer) {
    stopwatch.reset();
    callback(this);
  }
}
