import 'package:flutter/widgets.dart';
import 'package:ux/src/core/core.dart';

/// Builder signature receiving the created/listened reactive object.
typedef ReactiveBuilderDelegate<T extends Listenable> = Widget Function(
  BuildContext context,
  T bloc,
  Widget? child,
);

typedef ReactiveBuilderUpdateDelegate<T extends Listenable> = void Function(
  BuildContext context,
  T bloc,
);

/// Creation callback invoked once when no external value is provided.
typedef ReactiveCreateDelegate<T extends Listenable> = T Function(
  BuildContext context,
);

/// Creates (or uses provided) listenable and rebuilds on its notifications.
///
/// {@tool snippet}
/// Basic usage with externally provided bloc instance.
/// ```dart
/// final bloc = CounterBloc();
/// ReactiveBuilder.value(
///   bloc,
///   builder: (_, b, __) => Text('Count: \\${b.value.count}'),
/// );
/// ```
/// {@end-tool}
class ReactiveBuilder<T extends Listenable> extends StatefulWidget {
  const ReactiveBuilder({
    Key? key,
    required ReactiveCreateDelegate<T> create,
    required this.builder,
    this.child,
    this.onUpdate,
  })  : _value = null,
        _create = create,
        super(key: key);

  const ReactiveBuilder.value(
    T value, {
    Key? key,
    required this.builder,
    this.child,
    this.onUpdate,
  })  : _value = value,
        _create = null,
        super(key: key);

  /// Creates the listenable once; dependencies captured at creation time.
  final ReactiveCreateDelegate<T>? _create;

  /// Externally-owned listenable; not disposed by this widget.
  final T? _value;

  /// Builds subtree; invoked on each listenable change.
  final ReactiveBuilderDelegate<T> builder;

  final Widget? child;

  /// Delegate that gets called before every build.
  /// Useful to react to dependency changes before rendering.
  ///
  /// In [onUpdate] it is allowed to trigger changes that cause a rebuild.
  /// If you watch/listen to provided dependencies inside the delegate,
  /// changes to any of those will cause [onUpdate] to be called,
  /// followed by rebuilding the subtree via calling [builder].
  /// It will not trigger a rebuild of the parent by itself.
  ///
  /// Will also be called if the parent rebuilds for any reason, so you can
  /// also use it to react to externally controlled dependency changes.
  /// Will be called before the actual widget build.
  /// Can be used for explicitly watching provided values and marking the build
  /// dirty before the actual build happens.
  final ReactiveBuilderUpdateDelegate<T>? onUpdate;

  @override
  _ReactiveBuilderState<T> createState() => _ReactiveBuilderState();
}

class _ReactiveBuilderState<T extends Listenable>
    extends State<ReactiveBuilder<T>> {
  late T reactive;

  @override
  void initState() {
    super.initState();
    _initReactive();
  }

  @override
  void dispose() {
    _disposeReactive(widget);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ReactiveBuilder<T> oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget._value != widget._value) {
      _disposeReactive(oldWidget);
      _initReactive();
      _triggerBuild();
    }

    _callOnUpdate();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _callOnUpdate();
  }

  void _initReactive() {
    reactive = (widget._value ?? widget._create!(context))
      ..addListener(_triggerBuild);
  }

  void _disposeReactive(ReactiveBuilder<T> widget) {
    reactive.removeListener(_triggerBuild);
    if (reactive is Disposable && widget._value == null) {
      (reactive as Disposable).dispose();
    }
  }

  void _callOnUpdate() {
    widget.onUpdate?.call(context, reactive);
  }

  void _triggerBuild() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return widget.builder(
      context,
      reactive,
      widget.child,
    );
  }
}
