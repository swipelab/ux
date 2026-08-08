/// [Late] as in value is resolved later, but that may fail after loading.
/// We tend to have quite a few cases where a set of tree states (error,
/// loading, value) for pages.
sealed class Late<T> {
  factory Late.value(T value) => LateValue<T>(value);

  factory Late.loading() => const LateLoading();

  factory Late.error([dynamic error]) => LateError<T>(error);
}

extension LateExtension<T> on Late<T> {
  bool get isLoading => this is LateLoading;

  bool get isError => this is LateError;

  bool get isValue => this is LateValue;

  T? get value => this.isValue ? (this as LateValue).value : null;

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

class LateError<T> implements Late<T> {
  const LateError([this.error]);

  final dynamic error;

  @override
  bool operator ==(Object other) =>
      other is LateError &&
      other.runtimeType == runtimeType &&
      other.error == error;

  @override
  int get hashCode => Object.hashAll([error]);
}

class LateLoading<T> implements Late<T> {
  const LateLoading();

  @override
  bool operator ==(Object other) =>
      other is LateLoading && other.runtimeType == runtimeType;

  @override
  int get hashCode => 0;
}

class LateValue<T> implements Late<T> {
  const LateValue(this.value);

  final T value;

  @override
  bool operator ==(Object other) =>
      other is LateValue &&
      other.runtimeType == runtimeType &&
      other.value == value;

  @override
  int get hashCode => Object.hashAll([value]);
}
