import 'package:flutter/material.dart';

class BendBox extends StatelessWidget {
  final EdgeInsets inward;
  final Color color;

  BendBox({this.inward = const EdgeInsets.all(0), this.color = Colors.red});

  Widget build(BuildContext context) {
    return CustomPaint(painter: _BendBoxPainter(inward: inward, color: color));
  }
}

class _BendBoxPainter extends CustomPainter {
  final EdgeInsets inward;
  final Color color;

  _BendBoxPainter({this.inward, this.color});

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

  bool shouldRepaint(CustomPainter oldDelegate) => true;
}
