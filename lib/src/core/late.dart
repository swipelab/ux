/// [Late] as in value is resolved later, but that may fail after loading.
/// We tend to have quite a few cases where a set of tree states (error,
/// loading, value) for pages.
sealed class Late<T> {
  factory Late.value(T value) => LateValue<T>(value);

  factory Late.loading() => const LateLoading();

  factory Late.error([dynamic error]) => LateError<T>(error);
}

/// Inspects and folds a [Late] without writing the switch by hand.
extension LateExtension<T> on Late<T> {
  /// Whether resolution is still in flight.
  bool get isLoading => this is LateLoading;

  /// Whether resolution failed.
  bool get isError => this is LateError;

  /// Whether resolution succeeded.
  bool get isValue => this is LateValue;

  /// The resolved value, or `null` while loading or on error.
  T? get value => isValue ? (this as LateValue).value : null;

  /// Folds every state through its handler.
  R map<R>({
    required R Function(LateValue<T> e) value,
    required R Function(LateError<T> e) error,
    required R Function(LateLoading<T> e) loading,
  }) {
    final e = this;
    return switch (e) {
      LateLoading() => loading(e),
      LateError() => error(e),
      LateValue() => value(e),
    };
  }

  /// Folds the states given a handler, falling back to [orElse].
  R maybeMap<R>({
    required R Function() orElse,
    R Function(LateValue<T> e)? value,
    R Function(LateError<T> e)? error,
    R Function(LateLoading<T> e)? loading,
  }) {
    final e = this;
    return switch (e) {
      LateLoading() => loading == null ? orElse() : loading(e),
      LateError() => error == null ? orElse() : error(e),
      LateValue() => value == null ? orElse() : value(e),
    };
  }

  /// Folds the states given a handler, yielding `null` for the rest.
  R? mapOrNull<R>({
    R Function(LateValue<T> e)? value,
    R Function(LateError<T> e)? error,
    R Function(LateLoading<T> e)? loading,
  }) {
    final e = this;
    return switch (e) {
      LateLoading() => loading?.call(e),
      LateError() => error?.call(e),
      LateValue() => value?.call(e),
    };
  }

  /// Folds every state through its handler, unwrapped to the payload.
  R when<R>({
    required R Function() loading,
    required R Function(dynamic error) error,
    required R Function(T value) value,
  }) {
    final e = this;
    return switch (e) {
      LateLoading() => loading(),
      LateError() => error(e.error),
      LateValue() => value(e.value),
    };
  }

  /// Unwrapped [mapOrNull].
  R? whenOrNull<R>({
    R Function()? loading,
    R Function([dynamic error])? error,
    R Function(T value)? value,
  }) {
    final e = this;
    return switch (e) {
      LateLoading() => loading?.call(),
      LateError() => error?.call(e.error),
      LateValue() => value?.call(e.value),
    };
  }

  /// Unwrapped [maybeMap].
  R maybeWhen<R>({
    required R Function() orElse,
    R Function()? loading,
    R Function([dynamic error])? error,
    R Function(T value)? value,
  }) {
    final e = this;
    return switch (e) {
      LateLoading() => loading == null ? orElse() : loading(),
      LateError() => error == null ? orElse() : error(e.error),
      LateValue() => value == null ? orElse() : value(e.value),
    };
  }
}

/// The failed state of a [Late].
class LateError<T> implements Late<T> {
  /// Carries [error] as the cause of the failure.
  const LateError([this.error]);

  /// What went wrong, or `null` when the caller gave no cause.
  final dynamic error;

  @override
  bool operator ==(Object other) =>
      other is LateError &&
      other.runtimeType == runtimeType &&
      other.error == error;

  @override
  int get hashCode => Object.hashAll([error]);
}

/// The unresolved state of a [Late].
class LateLoading<T> implements Late<T> {
  /// The single loading state; all instances compare equal.
  const LateLoading();

  @override
  bool operator ==(Object other) =>
      other is LateLoading && other.runtimeType == runtimeType;

  @override
  int get hashCode => 0;
}

/// The resolved state of a [Late].
class LateValue<T> implements Late<T> {
  /// Carries [value] as the resolution.
  const LateValue(this.value);

  /// What resolution produced.
  final T value;

  @override
  bool operator ==(Object other) =>
      other is LateValue &&
      other.runtimeType == runtimeType &&
      other.value == value;

  @override
  int get hashCode => Object.hashAll([value]);
}
