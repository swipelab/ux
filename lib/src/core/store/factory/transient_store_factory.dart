import 'package:ux/src/core/core.dart';

/// Always produces a fresh instance on access.
class TransientStoreFactory<T> extends StoreFactory<T> with TransientFactory {
  /// Binds the [delegate] that builds each instance to the [locator] it
  /// resolves dependencies through.
  TransientStoreFactory({
    required this.locator,
    required this.delegate,
  });

  /// Builds one instance per access.
  final LocatorCreateDelegate<T> delegate;

  /// Dependency source passed to [delegate].
  final Locator locator;

  @override
  Future<T> get future async => instance;

  @override
  T get instance => delegate(locator);

  @override
  String toString() => 'Transient $T';
}
