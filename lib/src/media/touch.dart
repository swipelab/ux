import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:ux/src/media/design.dart';

/// A press target that fades and grows while it is held, and gives a light
/// haptic on a long press.
class Touch extends StatefulWidget {
  /// Wraps [child] in the press feedback.
  const Touch({
    super.key,
    this.child,
    this.onPress,
    this.onLongPress,
    this.padding,
    this.inflate = 0,
    this.fade = .8,
  });

  /// What is pressed.
  final Widget? child;

  /// Called on a tap; without it taps pass through.
  final VoidCallback? onPress;

  /// Called on a long press; without it long presses pass through.
  final VoidCallback? onLongPress;

  /// Space around [child] that also takes the press.
  final EdgeInsetsGeometry? padding;

  /// Logical pixels the target grows by on its longer side while held.
  final double inflate;

  /// Opacity of [child] while held.
  final double fade;

  @override
  State<Touch> createState() => _TouchState();
}

class _TouchState extends State<Touch> {
  bool isTap = false;
  bool isLong = false;

  bool get isDown => isTap || isLong;

  double deltaScale = 0;

  @override
  Widget build(BuildContext context) {
    final deltaScale = isDown ? this.deltaScale : 0.0;
    return GestureDetector(
      onTap: widget.onPress == null ? null : _handleTap,
      onTapDown: widget.onPress == null ? null : _handleTapDown,
      onTapCancel: widget.onPress == null ? null : _handleTapCancel,
      onTapUp: widget.onPress == null ? null : _handleTapUp,
      onLongPressDown: widget.onLongPress == null ? null : _handleLongPressDown,
      onLongPress: widget.onLongPress == null ? null : _handleLongPress,
      onLongPressCancel: widget.onLongPress == null
          ? null
          : _handleLongPressCancel,
      onLongPressUp: widget.onLongPress == null ? null : _handleLongPressUp,
      behavior: HitTestBehavior.translucent,
      child: AnimatedContainer(
        duration: kAnimation,
        padding: widget.padding,
        transform: Matrix4.identity()
          ..scaleByDouble(1 + deltaScale, 1 + deltaScale, 1, 1),
        transformAlignment: Alignment.center,
        child: AnimatedOpacity(
          opacity: isDown ? widget.fade : 1,
          duration: kAnimation,
          child: widget.child,
        ),
      ),
    );
  }

  void _handleTap() => widget.onPress?.call();

  void _handleLongPress() {
    if (widget.onLongPress == null) return;
    HapticFeedback.lightImpact();
    widget.onLongPress!();
  }

  double _resolveDeltaScale() {
    final size = context.size;
    if (size == null || size.width == 0 || size.height == 0) return 0;
    return math.min(widget.inflate / size.width, widget.inflate / size.height);
  }

  void _handleTapDown(TapDownDetails details) {
    isTap = true;
    deltaScale = _resolveDeltaScale();
    setState(() {});
  }

  void _handleTapCancel() {
    isTap = false;
    setState(() {});
  }

  void _handleLongPressDown(LongPressDownDetails details) {
    isLong = true;
    deltaScale = _resolveDeltaScale();
    setState(() {});
  }

  void _handleLongPressCancel() {
    isLong = false;
    setState(() {});
  }

  void _handleTapUp(TapUpDetails details) => _handleTapCancel();

  void _handleLongPressUp() => _handleLongPressCancel();
}
