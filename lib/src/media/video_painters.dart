import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Hand-tuned 15×18 right-pointing triangle with a +1.5pt rightward
/// optical-centre bias, mirroring `RadialStatusIconContentNode.swift:80-87`.
/// Used by both the chat bubble's play overlay and the gallery's center
/// status overlay.
class PlayTrianglePainter extends CustomPainter {
  /// Creates the painter in [color].
  PlayTrianglePainter(this.color);

  /// Fill of the triangle.
  final Color color;

  static const double _w = 15.0;
  static const double _h = 18.0;
  static const double _opticalBias = 1.5;

  @override
  void paint(Canvas canvas, Size size) {
    final dx = (size.width - _w) / 2.0 + _opticalBias;
    final dy = (size.height - _h) / 2.0;
    final path = Path()
      ..moveTo(dx, dy)
      ..lineTo(dx + _w, dy + _h / 2.0)
      ..lineTo(dx, dy + _h)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(PlayTrianglePainter old) => old.color != color;
}

/// Two parallel vertical bars matching iOS Telegram's pause glyph on
/// the gallery's centre overlay (`PlayPauseIconNode` rendering of the
/// `.pause` state). Sized to the same 18pt visual height as the play
/// triangle so the two glyphs swap in place without a layout jump.
class PauseBarsPainter extends CustomPainter {
  /// Creates the painter in [color].
  PauseBarsPainter(this.color);

  /// Fill of the bars.
  final Color color;

  static const double _h = 18.0;
  static const double _barWidth = 4.5;
  static const double _gap = 4.5;

  @override
  void paint(Canvas canvas, Size size) {
    final totalWidth = _barWidth * 2 + _gap;
    final dx = (size.width - totalWidth) / 2.0;
    final dy = (size.height - _h) / 2.0;
    final paint = Paint()..color = color;
    final radius = Radius.circular(_barWidth / 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(dx, dy, _barWidth, _h), radius),
      paint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(dx + _barWidth + _gap, dy, _barWidth, _h),
        radius,
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(PauseBarsPainter old) => old.color != color;
}

/// Round-cap progress / spinner ring matching
/// `RadialProgressContentNode.swift:147-158`.
///
/// Two modes:
/// - [progress] non-null: determinate arc from 12 o'clock sweeping clockwise
///   by `progress * 2π` (used during file download with known total bytes).
/// - [progress] null: indeterminate 90° arc rotated by [rotation] each tick
///   (used during buffering with unknown progress).
class RadialRingPainter extends CustomPainter {
  /// Creates the ring painter.
  RadialRingPainter({
    required this.color,
    required this.strokeWidth,
    required this.rotation,
    this.progress,
  });

  /// Stroke of the arc.
  final Color color;

  /// Width of the arc's stroke.
  final double strokeWidth;

  /// Angle of the indeterminate arc's start from 12 o'clock, in radians.
  final double rotation;

  /// Fraction done, 0 to 1; absent while the total is unknown.
  final double? progress;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = strokeWidth
      ..color = color;
    // Inset by stroke + ~2.5pt gap from disc edge (matches the iOS
    // `lineWidth + 2.5*2` convention at RadialProgressContentNode:153).
    final inset = strokeWidth + 2.5;
    final rect = Rect.fromCircle(
      center: Offset(size.width / 2, size.height / 2),
      radius: math.min(size.width, size.height) / 2 - inset,
    );
    final p = progress;
    if (p == null) {
      const sweep = math.pi / 2.0;
      canvas.drawArc(rect, rotation - math.pi / 2.0, sweep, false, paint);
    } else {
      final clamped = p.clamp(0.0, 1.0);
      final sweep = clamped * 2.0 * math.pi;
      canvas.drawArc(rect, -math.pi / 2.0, sweep, false, paint);
    }
  }

  @override
  bool shouldRepaint(RadialRingPainter old) =>
      old.color != color ||
      old.strokeWidth != strokeWidth ||
      old.rotation != rotation ||
      old.progress != progress;
}
