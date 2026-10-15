import 'package:flutter/widgets.dart';

/// Drives a builder with a double that animates from [start] to [end], and
/// again to each new [end] the widget is rebuilt with.
class AnimatedDouble extends StatefulWidget {
  /// Binds the animated range, its timing, and the builder it drives.
  const AnimatedDouble({
    super.key,
    required this.builder,
    required this.start,
    required this.end,
    this.curve = Curves.linear,
    this.duration = const Duration(milliseconds: 200),
    this.child,
  });

  /// Rebuilt on every tick with the current value and [child].
  final ValueWidgetBuilder<double> builder;

  /// Subtree passed through to [builder] untouched by ticks.
  final Widget? child;

  /// Value the animation holds on the first frame.
  final double start;

  /// Value the animation runs toward; changing it restarts the run.
  final double end;

  /// Time a full run takes.
  final Duration duration;

  /// Shape of the run over [duration].
  final Curve curve;

  @override
  State<AnimatedDouble> createState() => _AnimatedDoubleState();
}

class _AnimatedDoubleState extends State<AnimatedDouble>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller;

  @override
  void initState() {
    super.initState();
    controller = AnimationController.unbounded(
      vsync: this,
      value: widget.start,
      duration: widget.duration,
    );
    if (widget.end != widget.start) {
      controller.animateTo(widget.end);
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant AnimatedDouble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.end != oldWidget.end) {
      controller.animateTo(widget.end);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: controller,
      builder: widget.builder,
      child: widget.child,
    );
  }
}
