import 'package:ux/src/media/design.dart';
import 'package:flutter/cupertino.dart';
import 'package:ux/src/media/touch.dart';
import 'package:ux/ux.dart';

const _amber = Color(0xFFFFC107);

/// A bolt in a circle that fills amber when [on], struck through when off.
class FlashButton extends StatelessWidget {
  /// Creates the button.
  const FlashButton({
    super.key,
    required this.onPress,
    required this.on,
    this.padding = EdgeInsets.zero,
  });

  /// Called on a tap.
  final VoidCallback onPress;
  /// Whether the flash is on.
  final bool on;
  /// Extends the touch area around the circle.
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Touch(
      padding: padding,
      onPress: onPress,
      child: AnimatedDouble(
        start: 0.0,
        end: on ? 1.0 : 0.0,
        curve: Curves.easeInOutCubicEmphasized,
        builder: (context, t, child) => CustomPaint(
          foregroundPainter: FlashPainter(t),
          child: Container(
            decoration: BoxDecoration(
              color: Color.lerp(const Color(0x00000000), _amber, t),
              shape: BoxShape.circle,
              border: Border.all(
                color: Color.lerp(
                  colors.onMedia.withValues(alpha: .6),
                  _amber,
                  t,
                )!,
              ),
            ),
            padding: const EdgeInsets.all(3),
            child: Icon(
              CupertinoIcons.bolt_fill,
              color: Color.lerp(colors.onMedia, const Color(0xFF000000), t),
              size: 16,
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints the strike-through of the flash button, shrinking to nothing as [t]
/// reaches 1.
class FlashPainter extends CustomPainter {
  /// Creates the painter at [t].
  const FlashPainter(this.t);

  /// 0 when the flash is off, 1 when on.
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    const pad = 0.1;
    final target = (1 - t - pad).clamp(pad, 1 - pad);
    if (pad == target) return;

    final start = Offset(size.width, size.height) * pad;
    final end = Offset(size.width, size.height) * target;
    canvas.drawLine(
      start,
      end,
      Paint()
        ..color = const Color(0xFF000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawLine(
      start,
      end,
      Paint()
        ..color = colors.onMedia
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant FlashPainter oldDelegate) => t != oldDelegate.t;
}
