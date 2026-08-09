import 'package:flutter/widgets.dart';
import 'package:ux/src/core/core.dart';

/// Provides a [Store] to the widget tree without creating an inherited
/// dependency (safe for `initState` reads).
class StoreProvider extends StatelessWidget {
  /// Publishes [store] to the subtree [builder] produces.
  const StoreProvider({
    required this.store,
    required this.builder,
    super.key,
  });

  /// The store this subtree resolves against.
  final Store store;

  /// Builds the subtree, below the provider in the tree.
  final WidgetBuilder builder;

  /// The nearest enclosing provider. Asserts when there is none.
  static StoreProvider of(BuildContext context) {
    final result = context.findAncestorWidgetOfExactType<StoreProvider>();
    assert(result != null, 'StoreProvider not found');
    return result!;
  }

  @override
  Widget build(BuildContext context) => Builder(builder: builder);
}
