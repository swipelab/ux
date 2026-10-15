import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:ux/src/media/design.dart';
import 'package:ux/src/media/editors/crop_image_layer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:vector_math/vector_math_64.dart' as vmath;

/// Screen-px drop from `crop.bottom` to the dial's 0° tick.
const double kCropDialTickInset = 42;

/// Screen-px gap between the 0° tick and the needle.
const double kCropDialNeedleGap = 12;

/// Screen-px side of the filled-triangle needle.
const double kCropDialNeedleSize = 9;

/// How far `CropAreaOverlay`'s bottom handles extend below `crop.bottom`:
/// half the 44pt control. The extra 16pt slop stays on the crop side, so
/// the ticks in the gutter are the dial's.
const double kCropDialHandleReach = 22;

/// Screen-px strip under the handle reach that the dial grabs alone.
const double kCropDialGrabStrip = 60;

/// Gutter between `crop.bottom` and the chrome, reserved by
/// `CropScreen`'s published fit rect: tall enough for the painted dial
/// and for a grab strip clear of the bottom handle's reach.
final double kCropDialBandHeight = math.max(
  kCropDialTickInset + kCropDialNeedleGap + kCropDialNeedleSize,
  kCropDialHandleReach + kCropDialGrabStrip,
);

/// Paints the rotation dial's guides in image space: a tick circle whose
/// lowest point marks [rotate] and a fixed needle under it.
///
/// [viewport] is the camera-mapped visible rect in image space and
/// [scale] the inverse camera scale, so every screen-px metric above
/// lands on screen at its literal size. [rotate] is the render angle —
/// the ticks turn with the image, not with the data state.
void paintCropRotationDial(
  Canvas canvas, {
  required Rect crop,
  required double rotate,
  required Rect viewport,
  required double scale,
}) {
  final r = viewport.width * .5;
  final center = crop.bottomCenter - Offset(0, r - kCropDialTickInset * scale);

  canvas.save();
  canvas.clipRect(
    Rect.fromLTRB(viewport.left, crop.bottom, viewport.right, viewport.bottom),
  );

  final dotBig = Paint()
    ..color = colors.onMedia
    ..style = PaintingStyle.stroke
    ..strokeWidth = 5 * scale
    ..strokeCap = StrokeCap.round;
  final dotSmall = Paint()
    ..color = colors.onMedia
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2 * scale
    ..strokeCap = StrokeCap.round;

  for (int angle = 0; angle < 180; angle += 2) {
    final a1 = rotate + angle * vmath.degrees2Radians;
    final a2 = rotate - angle * vmath.degrees2Radians;
    final p1 = center + _onCircle(r, a1);
    final p2 = center + _onCircle(r, a2);
    final labelled = angle % 10 == 0;

    canvas.drawPoints(ui.PointMode.points, [
      p1,
      p2,
    ], labelled ? dotBig : dotSmall);
    if (labelled) {
      _drawAngleLabel(canvas, '${-angle}', a1, center, p1, scale);
      _drawAngleLabel(canvas, '$angle', a2, center, p2, scale);
    }
  }

  _drawNeedle(
    canvas,
    Offset(center.dx, center.dy + r + kCropDialNeedleGap * scale),
    scale,
  );

  canvas.restore();
}

Offset _onCircle(double r, double angle) {
  final v = vmath.Vector3(0, r, 0)
    ..applyAxisAngle(vmath.Vector3(0, 0, 1), angle);
  return Offset(v.x, v.y);
}

void _drawNeedle(Canvas canvas, Offset tip, double scale) {
  final side = kCropDialNeedleSize * scale;
  final path = Path()
    ..moveTo(side * .5, 0)
    ..lineTo(side, side)
    ..lineTo(0, side)
    ..close();

  canvas.save();
  canvas.translate(tip.dx - side / 2, tip.dy);
  canvas.drawPath(path, Paint()..color = colors.onMedia);
  canvas.restore();
}

void _drawAngleLabel(
  Canvas canvas,
  String label,
  double angle,
  Offset center,
  Offset anchor,
  double scale,
) {
  final text = TextPainter(
    text: TextSpan(
      text: label,
      style: TextStyle(
        fontFamily: mediaFontFamily,
        fontSize: 12 * scale,
        fontWeight: FontWeight.w600,
        color: colors.onMedia,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();

  final toCenter = center - anchor;
  final inset = (text.height * .5 + 4 * scale) / toCenter.distance;
  final at = anchor + toCenter * inset;

  canvas.save();
  canvas.translate(at.dx, at.dy);
  canvas.rotate(angle);
  text.paint(canvas, -Offset(text.width / 2, text.height / 2));
  canvas.restore();
}

/// Screen-px of horizontal travel per degree of rotation.
const double _kDialPixelsPerDegree = math.pi * 1.15;

/// The dial's gesture band: full viewport width, from `crop.bottom`
/// down to the bottom of the editor body. Dragging it turns the image
/// and re-covers the crop on every update, never zooming below
/// [CropImageLayer.rotationScaleFloor], so a drag out and back returns
/// the zoom the user had. A double tap springs the rotation back to 0
/// through [CropImageLayer.resetRotation].
///
/// Mounted BEFORE [CropAreaOverlay] so the bottom handles win the strip
/// the two overlap.
class CropRotationDial extends StatefulWidget {
  /// Turns the image of [layer] as [hostCamera] shows it.
  const CropRotationDial({
    super.key,
    required this.layer,
    required this.hostCamera,
  });

  /// The layer whose rotation is dragged.
  final CropImageLayer layer;

  /// The image-to-screen transform the band is placed through.
  final ValueListenable<vmath.Matrix4> hostCamera;

  @override
  State<CropRotationDial> createState() => CropRotationDialState();
}

/// Claims the pointer at touch-down, so a drag starting inside the
/// stack's 40px edge-swipe strip turns the dial instead of popping the
/// screen, and so the dial owns the gesture before a second finger can
/// start a pinch.
class _DialDragRecognizer extends PanGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

/// State of a [CropRotationDial]; tests read its counters.
class CropRotationDialState extends State<CropRotationDial> {
  /// Completed double taps on the band.
  int doubleTaps = 0;

  /// This pointer owns the dial — begin was not refused.
  bool _tracking = false;

  /// The gesture has moved at least once, so it is a drag rather than
  /// a tap: only then does the grid show and the settle spring run.
  bool _moved = false;

  double _baseRotate = 0;
  double _totalDx = 0;
  Offset _pending = Offset.zero;
  PointerDeviceKind? _kind;

  int _taps = 0;
  Timer? _tapTimer;

  @override
  void initState() {
    super.initState();
    widget.layer.addListener(_relayout);
    widget.hostCamera.addListener(_relayout);
  }

  @override
  void dispose() {
    widget.layer.removeListener(_relayout);
    widget.hostCamera.removeListener(_relayout);
    if (_tracking) _end();
    _tapTimer?.cancel();
    super.dispose();
  }

  void _relayout() {
    if (mounted) setState(() {});
  }

  /// `crop.bottom` in viewport coordinates (camera is scale + translate).
  double get _areaBottom {
    final m = widget.hostCamera.value;
    return widget.layer.crop.bottom * m.storage[0] + m.storage[13];
  }

  void _begin(DragStartDetails details) {
    final layer = widget.layer;
    if (layer.scrollTracking || layer.areaTracking) return;
    _tracking = true;
    _moved = false;
    _totalDx = 0;
    _pending = Offset.zero;
    _kind = details.kind;
    layer.dialTracking = true;
  }

  /// Pointer travel past the device hit slop is a drag; within it the
  /// lift is a tap (and a second tap resets rotation).
  double get _hitSlop => computeHitSlop(_kind ?? PointerDeviceKind.touch, null);

  void _update(Offset delta) {
    if (!_tracking) return;
    final layer = widget.layer;
    if (!_moved) {
      _pending += delta;
      if (_pending.distance <= _hitSlop) return;
      _moved = true;
      _taps = 0;
      _tapTimer?.cancel();
      layer.beginInteraction();
      _baseRotate = layer.renderRotate;
      layer.captureRotationFloor();
      _totalDx = _pending.dx;
    } else {
      _totalDx += delta.dx;
    }
    layer.rotateCovered(
      _baseRotate + vmath.degrees2Radians * (-_totalDx / _kDialPixelsPerDegree),
      scaleFloor: layer.rotationScaleFloor,
    );
  }

  void _end() {
    if (!_tracking) return;
    _tracking = false;
    if (_moved) {
      widget.layer.endInteraction();
    } else {
      _countTap();
    }
    widget.layer.dialTracking = false;
  }

  void _countTap() {
    _tapTimer?.cancel();
    if (++_taps == 2) {
      _taps = 0;
      doubleTaps++;
      widget.layer.resetRotation();
      return;
    }
    _tapTimer = Timer(kDoubleTapTimeout, () => _taps = 0);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.hostCamera.value.storage[0].abs() < 1e-9) {
      return SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.biggest;
        final band = Rect.fromLTRB(
          0,
          _areaBottom,
          viewport.width,
          viewport.height,
        );
        if (band.isEmpty) return SizedBox.shrink();
        return Stack(
          children: [
            Positioned.fromRect(
              rect: band,
              child: RawGestureDetector(
                behavior: HitTestBehavior.opaque,
                gestures: <Type, GestureRecognizerFactory>{
                  _DialDragRecognizer:
                      GestureRecognizerFactoryWithHandlers<_DialDragRecognizer>(
                        _DialDragRecognizer.new,
                        (r) => r
                          ..onStart = _begin
                          ..onUpdate = ((d) => _update(d.delta))
                          ..onEnd = ((_) => _end())
                          ..onCancel = _end,
                      ),
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
