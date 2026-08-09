import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';

import 'dispose.dart';
import 'emitter.dart';

/// Read/write access to a single [T], however it is stored.
mixin Value<T> {
  /// Writes the held value.
  set value(T value);

  /// The held value.
  T get value;
}

/// A [Value] backed by a getter/setter pair rather than a field.
class DelegatedValue<T> with Dispose, Value<T> {
  /// Binds the pair the value is read from and written through.
  DelegatedValue({required this.setter, required this.getter});

  /// Receives every write to [value].
  final ValueSetter<T> setter;

  /// Answers every read of [value].
  final ValueGetter<T> getter;

  @override
  set value(T value) => setter(value);

  @override
  T get value => getter();
}

/// Exposes an [AnimationController]'s progress as a [Value].
extension ValueAnimationControllerExtension on AnimationController {
  /// Wraps this controller's `value` as a standalone [Value].
  DelegatedValue<double> delegate() {
    return DelegatedValue<double>(
      setter: (e) => value = e,
      getter: () => value,
    );
  }

  /// Keeps this controller and [other] at the same value in both
  /// directions, seeding the controller from [other]. Dispose the result to
  /// break the link.
  Disposable link(ValueEmitter<double> other) {
    final it = this;
    final diposer = Dispose();

    void intoOther() {
      if (other.value == it.value) return;
      other.value = it.value;
    }

    void intoIt() {
      if (other.value == it.value) return;
      it.value = other.value;
    }

    it.subscribe(intoOther).disposeBy(diposer);
    other.subscribe(intoIt).disposeBy(diposer);

    intoIt();

    return diposer;
  }
}
