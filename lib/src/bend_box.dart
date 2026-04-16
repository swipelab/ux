import 'package:flutter/material.dart';

/// A widget that paints a filled shape with curved (bent) edges.
///
/// Each edge bends inward by the amount specified in [inward].
class BendBox extends StatelessWidget {
  /// How far each edge bends inward. Positive values bend toward the center.
  final EdgeInsets inward;

  /// The fill color of the shape.
  final Color color;

  /// Creates a [BendBox] with the given [inward] bend and [color].
  const BendBox({super.key, this.inward = const EdgeInsets.all(0), this.color = Colors.red});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _BendBoxPainter(inward: inward, color: color));
  }
}

class _BendBoxPainter extends CustomPainter {
  final EdgeInsets inward;
  final Color color;

  _BendBoxPainter({
    required this.inward,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.fill
      ..isAntiAlias = true
      ..color = color;

    final path = Path()
      ..moveTo(0, 0)
      ..quadraticBezierTo(size.width / 2, inward.top, size.width, 0)
      ..quadraticBezierTo(
          size.width - inward.left, size.height / 2, size.width, size.height)
      ..quadraticBezierTo(
          size.width / 2, size.height - inward.bottom, 0, size.height)
      ..quadraticBezierTo(inward.left, size.height / 2, 0, 0)
      ..close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => true;
}
