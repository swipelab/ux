import 'package:flutter/widgets.dart';

/// Drives a builder with a colour that tweens to each new [color] the widget
/// is rebuilt with.
class AnimatedColor extends StatefulWidget {
  /// Binds the target colour, its timing, and the builder it drives.
  const AnimatedColor({
    required this.color,
    required this.builder,
    this.child,
    this.curve = Curves.linear,
    this.duration = const Duration(milliseconds: 200),
    super.key,
  });

  /// Shape of the tween over [duration].
  final Curve curve;

  /// Time a full tween takes.
  final Duration duration;

  /// Colour the tween runs toward; changing it starts a new tween.
  final Color? color;

  /// Rebuilt on every tick with the current colour and [child].
  final ValueWidgetBuilder<Color?> builder;

  /// Subtree passed through to [builder] untouched by ticks.
  final Widget? child;

  @override
  State<AnimatedColor> createState() => _AnimatedColorState();
}

class _AnimatedColorState extends State<AnimatedColor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animationController;
  late Animation<Color?> _colorAnimation;

  @override
  void initState() {
    super.initState();

    _animationController =
        AnimationController(duration: widget.duration, vsync: this);
    _colorAnimation =
        ColorTween(begin: widget.color, end: widget.color).animate(
      CurvedAnimation(parent: _animationController, curve: widget.curve),
    );
  }

  @override
  void didUpdateWidget(AnimatedColor oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.color != widget.color) {
      _colorAnimation =
          ColorTween(begin: oldWidget.color, end: widget.color).animate(
        CurvedAnimation(parent: _animationController, curve: widget.curve),
      );
      _animationController.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _colorAnimation,
      builder: (context, child) =>
          widget.builder(context, _colorAnimation.value, child),
    );
  }
}
