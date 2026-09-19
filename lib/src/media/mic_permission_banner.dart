import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../camera.dart';
import 'design.dart';
import 'touch.dart';

/// Compact pill shown above the camera shutter when the user is in
/// video mode but mic permission isn't (yet) granted. Tapping routes
/// through [XCameraController.requestAudioPermission] — the native
/// side shows the in-app system prompt when the OS will, and
/// deep-links to Settings on permanent denial. The page is
/// responsible for re-polling permission on `AppLifecycleState.resumed`.
class MicPermissionBanner extends StatefulWidget {
  /// Shows [label] and reports a tap.
  const MicPermissionBanner({
    super.key,
    required this.label,
    required this.onTap,
  });

  /// The invitation to turn the microphone on.
  final String label;

  /// Called on a tap.
  final VoidCallback onTap;

  @override
  State<MicPermissionBanner> createState() => _MicPermissionBannerState();
}

class _MicPermissionBannerState extends State<MicPermissionBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Touch(
      onPress: widget.onTap,
      child: Container(
        padding: space.banner,
        decoration: BoxDecoration(
          color: colors.onMedia.withValues(alpha: .14),
          borderRadius: BorderRadius.all(Radius.circular(radius.pill)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 18,
              height: 14,
              child: AnimatedBuilder(
                animation: _ctrl,
                builder: (context, _) => CustomPaint(
                  painter: _WaveformPainter(
                    phase: _ctrl.value,
                    color: colors.onMedia,
                  ),
                ),
              ),
            ),
            SizedBox(width: space.sm),
            Text(
              widget.label,
              style: text.body.copyWith(
                color: colors.onMedia,
                fontWeight: FontWeight.w500,
              ),
            ),
            SizedBox(width: space.xs),
            Icon(icons.micSlash, color: colors.onMedia, size: 14),
          ],
        ),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({required this.phase, required this.color});

  final double phase;
  final Color color;

  static const _barCount = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final barWidth = 2.0;
    final gap = (size.width - _barCount * barWidth) / (_barCount - 1);
    for (var i = 0; i < _barCount; i++) {
      final t = (phase + i / _barCount) % 1.0;
      final wave = 0.5 + 0.5 * math.sin(t * 2 * math.pi);
      final h = (0.35 + 0.65 * wave) * size.height;
      final x = i * (barWidth + gap);
      final rect = Rect.fromLTWH(x, (size.height - h) / 2, barWidth, h);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(1)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.phase != phase || old.color != color;
}
