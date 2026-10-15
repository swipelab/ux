import 'dart:async';

import 'package:flutter/foundation.dart';

/// Quiet period a [Debouncer] waits for when none is given.
const kDefaultDebounce = Duration(milliseconds: 100);

/// Utility that delays execution of the last scheduled callback until
/// [duration] has elapsed without a new schedule.
class Debouncer {
  /// Binds the quiet period every [run] waits for by default.
  Debouncer({this.duration = kDefaultDebounce});

  /// Quiet period [run] waits for when it is given no override.
  final Duration duration;

  /// The pending timer, or `null` when nothing is scheduled.
  Timer? timer;

  /// Schedules [f] to run after [duration]; resets the timer if called again.
  void run(FutureOr<void> Function() f, {Duration? duration}) {
    timer?.cancel();
    timer = Timer(duration ?? this.duration, f);
  }

  /// Cancels a pending scheduled callback, if any.
  void cancel() => timer?.cancel();
}

/// Returns a closure that debounces calls to [f] by [duration]. Re‑invocation
/// resets the timer. Useful for text search, resize, etc.
VoidCallback debounce(
  FutureOr<void> Function() f, [
  Duration duration = kDefaultDebounce,
]) {
  final debouncer = Debouncer(duration: duration);
  return () => debouncer.run(f);
}
