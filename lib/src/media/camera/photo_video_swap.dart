import 'package:ux/src/media/design.dart';
import 'package:flutter/material.dart';

const _amber = Color(0xFFFFC107);

/// The switch between photo and video.
class PhotoVideoSwap extends StatefulWidget {
  /// Creates the switch.
  const PhotoVideoSwap({
    super.key,
    required this.isPhoto,
    required this.onChanged,
  });

  /// Whether photo is chosen.
  final bool isPhoto;

  /// Called with the chosen mode, true for photo, on a tap or a settled swipe.
  final ValueChanged<bool> onChanged;

  @override
  State<PhotoVideoSwap> createState() => _PhotoVideoSwapState();
}

class _PhotoVideoSwapState extends State<PhotoVideoSwap>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(duration: kAnimation, vsync: this);
    _slideAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
    if (!widget.isPhoto) _controller.value = 1.0;
  }

  @override
  void didUpdateWidget(PhotoVideoSwap old) {
    super.didUpdateWidget(old);
    if (old.isPhoto != widget.isPhoto) {
      if (widget.isPhoto) {
        _controller.reverse();
      } else {
        _controller.forward();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => widget.onChanged(!widget.isPhoto),
        onHorizontalDragUpdate: (d) {
          final next = (_controller.value - d.delta.dx / 80).clamp(0.0, 1.0);
          _controller.value = next;
        },
        onHorizontalDragEnd: (d) {
          final velocity = d.velocity.pixelsPerSecond.dx;
          final shouldBeVideo = velocity < -500
              ? true
              : velocity > 500
              ? false
              : _controller.value > 0.5;
          final targetIsPhoto = !shouldBeVideo;
          if (targetIsPhoto != widget.isPhoto) {
            widget.onChanged(targetIsPhoto);
          } else {
            _controller.animateTo(
              widget.isPhoto ? 0.0 : 1.0,
              curve: Curves.easeOut,
            );
          }
        },
        child: SizedBox(
          height: 32,
          child: AnimatedBuilder(
            animation: _slideAnimation,
            builder: (context, _) {
              return OverflowBox(
                maxWidth: double.infinity,
                child: Transform.translate(
                  offset: Offset(40 - _slideAnimation.value * 80, 0),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _option('PHOTO', _slideAnimation.value, true),
                      _option('VIDEO', _slideAnimation.value, false),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _option(String label, double t, bool isPhoto) {
    final selectedness = isPhoto ? t : (1.0 - t);
    final textColor = Color.lerp(_amber, colors.onMedia, selectedness)!;
    final scale = 1.0 - (selectedness * 0.2);
    final opacity = 1.0 - (selectedness * 0.5);
    final rotationY = selectedness * 0.3 * (isPhoto ? 1 : -1);

    return Container(
      width: 80,
      height: 32,
      alignment: Alignment.center,
      child: Transform(
        transform: Matrix4.identity()
          ..setEntry(3, 2, 0.001)
          ..rotateY(rotationY),
        alignment: Alignment.center,
        child: Transform.scale(
          scale: scale,
          child: Opacity(
            opacity: opacity,
            child: Text(
              label,
              style: text.bodySmall.copyWith(
                color: textColor,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
