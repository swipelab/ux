import 'dart:async';

import 'package:ux/src/core/core.dart';

/// Lazily creates & caches an instance (supports [AsyncInit]).
class LazyStoreFactory<T> extends StoreFactory<T> {
  /// Binds the [delegate] that builds the instance to the [resolver] it
  /// resolves dependencies through.
  LazyStoreFactory({required this.resolver, required this.delegate});

  /// Builds the instance on first access.
  final ResolverCreateDelegate<T> delegate;

  /// Dependency source passed to [delegate].
  final Resolver resolver;
  Completer<T>? _completer;
  T? _instance;

  @override
  Future<T> get future async {
    if (_completer == null) {
      _completer = Completer<T>();
      final instance = await delegate(resolver);
      if (instance is AsyncInit) {
        await instance.init();
      }
      _instance = instance;
      _completer!.complete(instance);
    }
    return _completer!.future;
  }

  @override
  T get instance => _instance == null
      ? throw Exception('Service not initialized: $T')
      : _instance!;

  @override
  String toString() => 'Lazy $T ${_instance?.runtimeType}';
}
