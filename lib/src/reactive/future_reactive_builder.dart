import 'package:flutter/widgets.dart';
import 'package:ux/src/reactive/reactive.dart';

/// Awaits an async creation of a [Reactive] and rebuilds on its changes.
///
/// {@tool snippet}
/// Lazy async loading of a bloc.
/// ```dart
/// FutureReactiveBuilder<CounterState>(
///   future: (ctx) async => CounterBloc()..increment(),
///   builder: (_, state, __) => Text('Loaded: \\${state.count}'),
/// );
/// ```
/// {@end-tool}
class FutureReactiveBuilder<T> extends StatefulWidget {
  /// Binds the async factory to the builder its result drives.
  const FutureReactiveBuilder({
    required this.future,
    required this.builder,
    this.child,
    super.key,
  });

  /// Subtree passed through to [builder] untouched by rebuilds.
  final Widget? child;

  /// Async factory returning a [Reactive] instance.
  final Future<Reactive<T>> Function(BuildContext context) future;

  /// Builder invoked with the current state value once ready.
  final Widget Function(BuildContext context, T state, Widget? child) builder;

  @override
  State<FutureReactiveBuilder<T>> createState() =>
      _FutureReactiveBuilderState<T>();
}

class _FutureReactiveBuilderState<T> extends State<FutureReactiveBuilder<T>> {
  @override
  void initState() {
    super.initState();
    _initBloc();
  }

  Reactive<T>? _bloc;

  Future<void> _initBloc() async {
    final bloc = await widget.future(context);
    bloc.addListener(_notify);
    _bloc = bloc;

    // notify bloc is ready
    _notify();
  }

  void _notify() => setState(() {});

  void _disposeBloc() async {
    if (_bloc != null) {
      _bloc!
        ..removeListener(_notify)
        ..dispose();
      _bloc = null;
    }
  }

  @override
  void didUpdateWidget(FutureReactiveBuilder<T> oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.future != widget.future ||
        oldWidget.builder != widget.builder ||
        oldWidget.child != widget.child) {
      _disposeBloc();
      _initBloc();
    }
  }

  @override
  Widget build(BuildContext context) {
    return _bloc == null
        ? SizedBox.shrink()
        : widget.builder(context, _bloc!.value, widget.child);
  }
}
