import 'package:ux/src/media/design.dart';
import 'package:flutter/material.dart';

/// Paints a corner bracket in each corner of the viewfinder.
class CameraGuidelinePainter extends CustomPainter {
  /// Creates the painter.
  CameraGuidelinePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()..color = colors.onMedia;
    const lineExtent = 30.0;

    final tl = Offset.zero;
    canvas.drawLine(tl, tl + Offset(lineExtent, 0), linePaint);
    canvas.drawLine(tl, tl + Offset(0, lineExtent), linePaint);

    final tr = Offset(size.width - 1, 0);
    canvas.drawLine(tr, tr - Offset(lineExtent, 0), linePaint);
    canvas.drawLine(tr, tr + Offset(0, lineExtent), linePaint);

    final br = Offset(size.width - 1, size.height);
    canvas.drawLine(br, br - Offset(lineExtent, 0), linePaint);
    canvas.drawLine(br, br - Offset(0, lineExtent), linePaint);

    final bl = Offset(0, size.height);
    canvas.drawLine(bl, bl + Offset(lineExtent, 0), linePaint);
    canvas.drawLine(bl, bl - Offset(0, lineExtent), linePaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
