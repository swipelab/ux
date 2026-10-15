import 'dart:async';

import 'package:flutter/foundation.dart';

import 'dispose.dart';

/// Core reactive mixin combining a private [ChangeNotifier] with disposal.
/// Extend / mix into classes that need manual `notifyListeners()` control.
mixin class Emitter implements Dispose, Listenable {
  final Dispose _dispose = Dispose();
  final _ChangeNotifier _notifier = _ChangeNotifier();

  @override
  @mustCallSuper
  void addDispose(VoidCallback callback) => _dispose.addDispose(callback);

  @override
  @mustCallSuper
  void addListener(VoidCallback listener) {
    _notifier.addListener(listener);
  }

  @override
  @mustCallSuper
  void removeListener(VoidCallback listener) {
    _notifier.removeListener(listener);
  }

  /// Notifies all registered listeners.
  @protected
  void notifyListeners() => _notifier.notifyListeners();

  @override
  @mustCallSuper
  void dispose() {
    _dispose.dispose();
    _notifier.dispose();
  }

  @override
  bool get disposed => _dispose.disposed;

  /// Whether there is at least one active listener.
  bool get hasListeners => _notifier.hasListeners;

  /// Creates a derived [LazyEmitter] recomputed when any [sources] fire.
  /// Emits only if the newly computed value differs from the cached value.
  static LazyEmitter<T> map<T>(List<Listenable> sources, ValueGetter<T> fn) {
    final notifier = LazyEmitter(fn);
    subscribe(sources, notifier.notifyListeners).disposeBy(notifier);
    return notifier;
  }

  /// handy way to addListener to a [ValueNotifier] and return the disposer callback
  static VoidCallback subscribe(
    Iterable<Listenable> sources,
    VoidCallback callback,
  ) {
    final subscriptions = sources.fold(
      <VoidCallback>[],
      (a, e) => a..add(e.subscribe(callback)),
    );
    return () {
      for (final subscription in subscriptions) {
        subscription();
      }
    };
  }

  /// Wraps [callback] so it is coalesced & scheduled in a microtask.
  static VoidCallback scheduled(VoidCallback callback) {
    var targetVersion = 0;
    var currentVersion = 0;
    return () {
      if (targetVersion == currentVersion) {
        targetVersion++;
        scheduleMicrotask(() {
          targetVersion = ++currentVersion;
          callback();
        });
      }
    };
  }
}

/// [ScheduledEmitter] allows listeners to be notified post frame.
/// Usage: enables notifications during a widget's `setState` without re-entrancy.
/// Not generally recommended—prefer standard emit patterns unless necessary.
class ScheduledEmitter with Emitter {
  /// Creates an emitter whose notifications land after the current frame.
  ScheduledEmitter();

  late final VoidCallback _scheduledNotifyListeners = Emitter.scheduled(
    super.notifyListeners,
  );

  @override
  void notifyListeners() => _scheduledNotifyListeners();
}

/// Exposes [notifyListeners] publicly (no protection) for advanced use cases.
class PublicEmitter extends Emitter {
  @override
  void notifyListeners() => super.notifyListeners();
}

class _ChangeNotifier extends ChangeNotifier {
  @override
  void notifyListeners() => super.notifyListeners();

  @override
  bool get hasListeners => super.hasListeners;
}

/// Mutable value holder emitting when [value] changes (shallow equality).
///
/// {@tool snippet}
/// ```dart
/// final counter = ValueEmitter<int>(0);
/// counter.addListener(() => print(counter.value));
/// counter.value++;
/// ```
/// {@end-tool}
class ValueEmitter<T> with Emitter implements ValueNotifier<T> {
  /// Starts holding the given value without emitting.
  ValueEmitter(this._value);

  T _value;

  @override
  T get value => _value;

  @override
  set value(T newValue) {
    if (_value == newValue) {
      return;
    }
    _value = newValue;
    notifyListeners();
  }
}

/// Lazily computes its value via [fn]. Recomputes on [update] if listeners
/// are attached and the value actually changes.
///
/// {@tool snippet}
/// ```dart
/// final a = ValueEmitter(1);
/// final b = ValueEmitter(2);
/// final sum = Emitter.map([a, b], () => a.value + b.value);
/// sum.addListener(() => print('sum: ${sum.value}'));
/// a.value = 10; b.value = 5; // triggers recompute
/// ```
/// {@end-tool}
class LazyEmitter<T> with Emitter implements ValueListenable<T> {
  /// Binds the computation behind [value].
  LazyEmitter(this.fn);

  /// Computes the current value on demand.
  final ValueGetter<T> fn;
  T? _lastValue;

  @override
  T get value => _lastValue ??= fn();

  @override
  void notifyListeners() {
    final newValue = fn();
    if (_lastValue != newValue) {
      _lastValue = newValue;
      super.notifyListeners();
    }
  }
}

/// Listening expressed as a disposable handle rather than a pair of calls.
extension ListenableExtension on Listenable {
  /// Adds [callback] as listener and returns a function to remove it.
  VoidCallback subscribe(VoidCallback callback) {
    addListener(callback);
    return () => removeListener(callback);
  }
}

/// Gives streams the same [subscribe] shape as [ListenableExtension].
extension StreamSubscriptionExtension<T> on Stream<T> {
  /// Listens with [callback] and returns a function that cancels it.
  VoidCallback subscribe(ValueChanged<T> callback) {
    return listen(callback).cancel;
  }
}

/// Hands a teardown callback's lifetime over to a collector.
extension VoidCallbackExtension on VoidCallback {
  /// Adds this callback to a [Dispose] aggregator for later invocation.
  void disposeBy(Dispose disposer) => disposer.addDispose(this);
}
