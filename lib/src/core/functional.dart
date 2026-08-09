/// Tolerance for double comparisons across the toolkit.
const kEpsilon = 0.001;

/// Generic function taking no params returning [T].
typedef Callback<T> = T Function();

/// Truthy test used across selection APIs.
typedef Predicate<T> = bool Function(T e);

/// Applies a function to any value in expression position.
extension ObjectFunctional<T> on T {
  /// Functional pipe: `value.pipe(fn)` -> `fn(value)`.
  R pipe<R>(R Function(T e) e) => e(this);
}

/// Identity helper (returns input unchanged).
T self<T>(T e) => e;

/// Executes a zero‑arg [Callback].
void call<T>(Callback<T> e) => e();

/// Constant-true [Callback], for APIs that demand one.
bool alwaysTrue() => true;

/// Constant-false [Callback], for APIs that demand one.
bool alwaysFalse() => false;

/// Reverse counterpart to `firstWhere`-style lookups.
extension IterableLastWhereOrNull<T> on Iterable<T> {
  /// The last element satisfying [test], or `null` when none does.
  T? lastWhereOrNull(bool Function(T) test) {
    T? result;
    for (final element in this) {
      if (test(element)) result = element;
    }
    return result;
  }
}
