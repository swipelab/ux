import 'package:flutter/foundation.dart';
import 'package:ux/src/core/core.dart';
import 'package:ux/src/reactive/reactive_builder.dart';

/// Base class for view models exposing a lazily built immutable state value.
/// Use with [ListenableBuilder] / [ReactiveBuilder]. Call [notifyListeners]
/// with an optional mutation callback to rebuild & emit only on value change.
///
/// {@tool snippet}
/// Simple counter bloc using [Reactive] and consumed via [ReactiveBuilder].
/// ```dart
/// class CounterState { const CounterState(this.count); final int count; }
/// class CounterBloc extends Reactive<CounterState> {
///   int _count = 0;
///   void increment() => notifyListeners(() => _count++);
///   @override CounterState buildState() => CounterState(_count);
/// }
///
/// Widget build(BuildContext context) => ReactiveBuilder<CounterBloc>(
///   create: (_) => CounterBloc(),
///   builder: (_, bloc, __) => Text('Count: \\${bloc.value.count}'),
/// );
/// ```
/// {@end-tool}
abstract class Reactive<T> with Emitter, Tasks implements ValueListenable<T> {
  /// The current value of the [Reactive].
  T? _value;

  /// The current value of the [Reactive].
  /// If [value] is null, [buildState] is called to build the value.
  @override
  T get value => _value ??= buildState();

  /// Override to build the derived state snapshot.
  @protected
  T buildState();

  /// Runs optional [callback], rebuilds state; notifies only if new value
  /// differs (using `==`).
  @override
  @protected
  @mustCallSuper
  void notifyListeners() async {
    final oldValue = _value;
    _value = buildState();

    if (oldValue != _value) {
      super.notifyListeners();
    }
  }

  @mustCallSuper
  @override
  void dispose() {
    disposeTasks();
    super.dispose();
  }
}
