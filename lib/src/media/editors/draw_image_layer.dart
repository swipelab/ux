import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:ux/src/media/editors/animator.dart';
import 'package:ux/src/media/editors/crop_image_layer.dart';
import 'package:ux/src/media/editors/editor.dart';
import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:ux/ux.dart';
import 'package:vector_math/vector_math_64.dart' as vmath;

/// Default eight-swatch palette. The last swatch is white so strokes read
/// on dark photos.
const List<Color> kDrawPalette = [
  Color(0xFFFF3B30),
  Color(0xFFFF9500),
  Color(0xFFFFCC00),
  Color(0xFF34C759),
  Color(0xFF5AC8FA),
  Color(0xFF0A84FF),
  Color(0xFFAF52DE),
  Color(0xFFFFFFFF),
];

/// The brushes of the draw tool.
enum BrushType {
  /// A line whose width follows the speed of the drag.
  pen,

  /// A pen line that ends in an arrowhead.
  arrow,

  /// A wide translucent line.
  marker,

  /// A glowing line.
  neon,

  /// Removes the strokes under it.
  eraser,
}

/// Each brush's starting thickness, 0 to 1 of its width range.
const Map<BrushType, double> kBrushDefaultThickness = <BrushType, double>{
  BrushType.pen: 0.25,
  BrushType.arrow: 0.25,
  BrushType.marker: 0.5,
  BrushType.neon: 0.5,
  BrushType.eraser: 0.5,
};

/// Per-brush min/max line widths in **logical screen pixels**. The
/// rendered on-screen stroke width = `currentThickness` directly
/// (image-space thickness × camera scale cancels out when stored as
/// `currentThickness / cameraScale`), so this maps 1:1 to what the
/// user sees and matches the brush-tool thickness indicator
/// (band width ≈ 20pt). Marker is slightly fatter — telegram's
/// 0.09 vs 0.07 max ratio applied to a 24pt baseline.
({double min, double max}) _brushSizeRange(BrushType type) {
  if (type == BrushType.marker) {
    return (min: 4.0, max: 28.0);
  }
  return (min: 1.0, max: 22.0);
}

/// Per-brush starting color. Each brush remembers its own color across
/// switches; tapping a swatch updates the currently active brush's slot,
/// not a global. Eraser keeps a slot for symmetry but its tip renders
/// as a fixed pink in the picker.
const Map<BrushType, Color> kBrushDefaultColors = <BrushType, Color>{
  BrushType.pen: Color(0xFFFF3B30),
  BrushType.arrow: Color(0xFFFF9500),
  BrushType.marker: Color(0xFFFFCC00),
  BrushType.neon: Color(0xFFAF52DE),
  BrushType.eraser: Color(0xFFFF3B30),
};

/// One sampled point along the user's drag. [width] is the rendered
/// stroke width at this point in image-space px (already EMA-smoothed
/// and velocity-modulated by [DrawImageLayer.addPoint]). [velocity] is
/// kept for arrow direction lookback and tests that synthesize strokes.
class StrokePoint {
  /// A sample at [position].
  const StrokePoint({
    required this.position,
    this.velocity = 0,
    this.width = 0,
  });

  /// Where the sample is, in image pixels.
  final Offset position;
  /// Smoothed speed of the drag at the sample, in image pixels per second.
  final double velocity;
  /// Rendered stroke width at the sample, in image pixels.
  final double width;
}

/// Telegram's pen width formula: subtract `velocity / 200` from the
/// chosen thickness, clamp to `[minWidth, thickness]`. Floor is 20% of
/// thickness — same as telegram's `renderMinLineWidth` (`minLW + (lineWidth - minLW) * 0.2`),
/// approximated here by treating `minLW` as 0 so the floor is purely
/// thickness-relative.
double _velocityWidth(double thickness, double velocity) {
  final minWidth = thickness * 0.2;
  final raw = thickness - velocity / 200.0;
  return raw.clamp(minWidth, thickness);
}

/// A finished stroke. [thickness] is in image-space (already divided by
/// the camera scale at submission time) so the rendered viewport width
/// stays constant across zoom levels.
class Stroke {
  /// A stroke through [points].
  Stroke({
    required this.points,
    required this.brushType,
    required this.color,
    required this.thickness,
    this.isArrow = false,
  });

  /// The samples, in drag order.
  final List<StrokePoint> points;
  /// The brush that drew it.
  final BrushType brushType;
  /// The stroke's colour.
  final Color color;
  /// The chosen thickness, in image pixels.
  final double thickness;
  /// Whether the stroke ends in an arrowhead.
  final bool isArrow;

  /// How much of the arrowhead is drawn, 0 to 1.
  double arrowProgress = 0;
  /// The arrowhead's tip; absent until an arrow stroke ends.
  Offset? arrowAnchor;
  /// Angle in radians from the tip back along the stroke, which the arms open
  /// around; absent until an arrow stroke ends.
  double? arrowDirection;

  /// Multiplier applied to the width of the tail (last N smooth points).
  /// 1.0 = fully committed (no thinning). 0.7 = freshly drawn, telegram's
  /// `activeWidthFactor`. The drying animator interpolates 0.7 → 1.0 over
  /// 400 ms after the stroke ends.
  double tailFactor = 1.0;
}

/// By-value snapshot of a [DrawImageLayer]'s mutable state. Captured
/// at tool-open by [DrawImageLayer.saveSnapshot]; consumed on cancel
/// by [DrawImageLayer.restoreSnapshot]. The strokes list is a shallow
/// copy — committed strokes are settled and don't mutate after the
/// drying animator completes, so reference-sharing is safe. Per-brush
/// color and thickness maps are deep-copied.
class DrawSnapshot {
  DrawSnapshot._({
    required this.strokes,
    required this.currentBrush,
    required this.brushColors,
    required this.normalizedThickness,
  });

  /// The committed strokes at capture.
  final List<Stroke> strokes;
  /// The selected brush at capture.
  final BrushType currentBrush;
  /// Each brush's colour at capture.
  final Map<BrushType, Color> brushColors;
  /// Each brush's thickness at capture.
  final Map<BrushType, double> normalizedThickness;
}

/// Free-draw layer with four brush types (pen / marker / neon / eraser),
/// per-brush thickness, velocity-aware width, and an optional arrow toggle
/// on pen. Strokes operate in image-space; the gesture surface translates
/// viewport coords via [toImageSpace].
///
/// The viewport-fitting matrix lives on the host (`ComposeEntry`); the
/// layer is told the current camera at paint time, and its scale is
/// captured at gesture-start time to size brush thickness in image-space.
class DrawImageLayer with Emitter, Painter, Exporter {
  /// Draws over [image], which the caller owns.
  DrawImageLayer({required this.image});

  /// The source image.
  final ui.Image image;
  /// [image]'s size in pixels.
  late final Size imageSize =
      Size(image.width.toDouble(), image.height.toDouble());

  /// The committed strokes, oldest first.
  final List<Stroke> strokes = <Stroke>[];
  /// The samples of the stroke in flight.
  final List<StrokePoint> currentPoints = <StrokePoint>[];

  /// The selected brush.
  BrushType currentBrush = BrushType.pen;

  /// Per-brush color memory. The layer's [currentColor] is a view onto
  /// this map at [currentBrush]; switching brushes loads that brush's
  /// remembered color.
  final Map<BrushType, Color> brushColors =
      Map<BrushType, Color>.from(kBrushDefaultColors);

  /// The selected brush's colour.
  Color get currentColor => brushColors[currentBrush]!;

  final Map<BrushType, double> _normalizedThickness =
      Map<BrushType, double>.from(kBrushDefaultThickness);

  /// The selected brush's thickness, 0 to 1 of its width range.
  double get normalizedThickness => _normalizedThickness[currentBrush]!;

  set normalizedThickness(double value) {
    final clamped = value.clamp(0.0, 1.0);
    if (_normalizedThickness[currentBrush] == clamped) return;
    _normalizedThickness[currentBrush] = clamped;
    notifyListeners();
  }

  /// The selected brush's thickness in logical screen pixels.
  double get currentThickness {
    final range = _brushSizeRange(currentBrush);
    return range.min + normalizedThickness * (range.max - range.min);
  }

  /// Camera scale captured at the start of the active gesture session.
  /// Strokes record their thickness as `currentThickness / scale` so the
  /// rendered viewport thickness stays constant regardless of how the
  /// host has scaled the camera. Updated only at [beginStroke] (and
  /// reset at end / cancel / restore) — mid-stroke camera changes don't
  /// retroactively rescale already-recorded points.
  double _activeCameraScale = 1.0;

  double get _brushThicknessImageSpace {
    if (_activeCameraScale.abs() < 1e-9) return currentThickness;
    return currentThickness / _activeCameraScale;
  }

  Offset? _previousPosition;
  int _previousTimestampMs = 0;
  double _previousVelocity = 0;
  double _previousWidth = 0;
  int _lastInputMs = 0;

  /// Per-brush min image-space distance between sampled points (telegram
  /// uses 8 / 10 / 10 pts at 1× zoom). The actual filter distance is
  /// divided by the camera scale so the sampled density stays consistent
  /// across zoom levels.
  static const Map<BrushType, double> _filterDistance = <BrushType, double>{
    BrushType.pen: 8.0,
    BrushType.arrow: 8.0,
    BrushType.marker: 10.0,
    BrushType.neon: 10.0,
    BrushType.eraser: 8.0,
  };

  /// Drop incoming `addPoint` calls that arrive within this many ms of
  /// the previous one. Matches telegram's `DrawingView.swift:283` throttle.
  static const int _inputThrottleMs = 16;

  /// Snapshot taken on tool-open. Tool-cancel calls [restoreSnapshot]
  /// to roll back to the captured state. Apply is a no-op (the layer's
  /// current state IS the committed state). Mirrors telegram-iOS's
  /// `previousDrawingData` (`MediaEditorScreen.swift:6086`).
  DrawSnapshot? _snapshot;

  /// Number of strokes already present when [saveSnapshot] ran. Strokes
  /// past this index were added during the current session — they're
  /// the ones [restoreSnapshotAnimated] fades out (via [_fadeNewStrokes])
  /// before snapping the layer back to the snapshot.
  int _snapshotStrokeCount = 0;

  /// Opacity multiplier applied to strokes added during the current
  /// session. 1.0 = fully visible (normal state). The fade-out animator
  /// drives this from 1 → 0 on [restoreSnapshotAnimated]; the snap
  /// then clears the now-invisible strokes and resets to 1.
  double _fadeNewStrokes = 1.0;

  late final Animator<double> _fadeAnimator = Animator<double>(
    getter: () => _fadeNewStrokes,
    setter: (v) {
      _fadeNewStrokes = v;
      notifyListeners();
    },
    curve: Curves.easeOut,
  )..disposeBy(this);

  /// True if at least one stroke has been committed (used by
  /// [ComposeEntry] to decide whether to rasterise on submit).
  bool get hasAppliedEdits => strokes.isNotEmpty;

  /// Capture current state for later [restoreSnapshot]. The strokes
  /// list is copied (shallow — stroke objects themselves are settled
  /// references). Per-brush color + thickness maps are deep-copied.
  void saveSnapshot() {
    _snapshot = DrawSnapshot._(
      strokes: List<Stroke>.of(strokes),
      currentBrush: currentBrush,
      brushColors: Map<BrushType, Color>.of(brushColors),
      normalizedThickness: Map<BrushType, double>.of(_normalizedThickness),
    );
    _snapshotStrokeCount = strokes.length;
  }

  /// Restore the layer to the last [saveSnapshot]. No-op if none saved.
  /// Any in-flight stroke is discarded.
  void restoreSnapshot() {
    final s = _snapshot;
    if (s == null) return;
    _fadeAnimator.cancel();
    _fadeNewStrokes = 1.0;
    strokes
      ..clear()
      ..addAll(s.strokes);
    _snapshotStrokeCount = strokes.length;
    currentBrush = s.currentBrush;
    brushColors
      ..clear()
      ..addAll(s.brushColors);
    _normalizedThickness
      ..clear()
      ..addAll(s.normalizedThickness);
    currentPoints.clear();
    _resetVelocityTracking();
    notifyListeners();
  }

  /// Like [restoreSnapshot] but fades out the strokes added during the
  /// current session before clearing them, so canceling a draw session
  /// is a smooth reverse instead of an instant disappear. Returns a
  /// Future that completes when the fade + snap finishes —
  /// `DrawScreen._cancel` fires this unawaited and then pops, so the
  /// fade overlaps with the screen pop transition.
  ///
  /// In-place eraser strokes don't visually un-erase (BlendMode.clear
  /// doesn't honour alpha), they just fade in alpha. The final snap
  /// at progress=0 restores the under-erased pixels in one frame —
  /// acceptable for the edge case.
  Future<void> restoreSnapshotAnimated() async {
    final s = _snapshot;
    if (s == null) return;
    await _fadeAnimator.animate(target: 0.0);
    _fadeNewStrokes = 1.0;
    strokes
      ..clear()
      ..addAll(s.strokes);
    _snapshotStrokeCount = strokes.length;
    currentBrush = s.currentBrush;
    brushColors
      ..clear()
      ..addAll(s.brushColors);
    _normalizedThickness
      ..clear()
      ..addAll(s.normalizedThickness);
    currentPoints.clear();
    _resetVelocityTracking();
    notifyListeners();
  }

  /// Interactive counterpart of [restoreSnapshotAnimated]'s fade: the
  /// draw screen maps swipe-back progress here so strokes drawn this
  /// session fade with the finger (t = 1 fully visible, 0 gone). An
  /// aborted swipe drives t back to 1 — full opacity, nothing to
  /// release. Committed strokes from before the snapshot are
  /// unaffected.
  void driveSnapshotRevert(double t) {
    if (_snapshot == null) return;
    _fadeAnimator.cancel();
    final v = t.clamp(0.0, 1.0).toDouble();
    if (_fadeNewStrokes == v) return;
    _fadeNewStrokes = v;
    notifyListeners();
  }

  /// Selects [type].
  void setBrushType(BrushType type) {
    if (currentBrush == type) return;
    currentBrush = type;
    notifyListeners();
  }

  /// Sets the selected brush's colour.
  void setCurrentColor(Color color) {
    if (brushColors[currentBrush] == color) return;
    brushColors[currentBrush] = color;
    notifyListeners();
  }

  /// Convert a viewport-space pointer position to image-space using the
  /// host [camera] (uniform scale + translate, no rotate).
  static Offset toImageSpace(Offset viewport, vmath.Matrix4 camera) {
    final scale = camera.storage[0];
    final tx = camera.storage[12];
    final ty = camera.storage[13];
    return Offset(
      (viewport.dx - tx) / scale,
      (viewport.dy - ty) / scale,
    );
  }

  /// Starts a stroke at [imagePoint], sizing it for a camera at [cameraScale].
  void beginStroke(Offset imagePoint, {double cameraScale = 1.0}) {
    currentPoints.clear();
    _activeCameraScale = cameraScale;
    _previousPosition = imagePoint;
    _previousTimestampMs = clock.now().millisecondsSinceEpoch;
    _previousVelocity = 0;
    _previousWidth = _brushThicknessImageSpace;
    // First addPoint after beginStroke must always pass the throttle —
    // the throttle is meant to thin high-frequency OS pointer events,
    // not the begin→first-add boundary.
    _lastInputMs = 0;
    currentPoints.add(
      StrokePoint(position: imagePoint, width: _previousWidth),
    );
    notifyListeners();
  }

  /// Adds [imagePoint] to the stroke in flight. False when the sample is
  /// dropped for coming too soon or too close to the last one.
  bool addPoint(Offset imagePoint) {
    final now = clock.now().millisecondsSinceEpoch;
    if (now - _lastInputMs < _inputThrottleMs) return false;

    final scale = _activeCameraScale;
    final filter = (_filterDistance[currentBrush] ?? 8.0) /
        (scale.abs() < 1e-6 ? 1.0 : scale.abs());
    if (_previousPosition != null) {
      final d = (imagePoint - _previousPosition!).distance;
      if (d < filter) return false;
    }
    _lastInputMs = now;

    var velocity = 0.0;
    if (_previousPosition != null && now > _previousTimestampMs) {
      final d = (imagePoint - _previousPosition!).distance;
      final dt = (now - _previousTimestampMs).toDouble();
      velocity = d / dt * 1000.0;
      velocity = velocity * 0.3 + _previousVelocity * 0.7;
    }

    final thickness = _brushThicknessImageSpace;
    var width = currentBrush == BrushType.eraser
        ? thickness
        : _velocityWidth(thickness, velocity);
    width = width * 0.3 + _previousWidth * 0.7;

    _previousPosition = imagePoint;
    _previousTimestampMs = now;
    _previousVelocity = velocity;
    _previousWidth = width;
    currentPoints.add(StrokePoint(
      position: imagePoint,
      velocity: velocity,
      width: width,
    ));
    notifyListeners();
    return true;
  }

  /// Discard the in-flight stroke's buffered points WITHOUT committing
  /// them as a [Stroke]. Used when the gesture system needs to switch
  /// modes mid-stroke (e.g. a second finger lands and we pivot from
  /// drawing to pan/zoom).
  void cancelStroke() {
    if (currentPoints.isEmpty) return;
    currentPoints.clear();
    _activeCameraScale = 1.0;
    _resetVelocityTracking();
    notifyListeners();
  }

  /// Commits the stroke in flight and starts the drying and arrow animations
  /// its brush has.
  void endStroke() {
    if (currentPoints.isEmpty) return;
    final stroke = Stroke(
      points: List<StrokePoint>.of(currentPoints),
      brushType: currentBrush,
      color: currentColor,
      thickness: _brushThicknessImageSpace,
      isArrow: currentBrush == BrushType.arrow,
    )..tailFactor = _activeWidthFactor;
    strokes.add(stroke);
    currentPoints.clear();
    _activeCameraScale = 1.0;
    _resetVelocityTracking();
    if (stroke.isArrow) {
      _computeArrowAnchor(stroke);
      _runArrowAnimation(stroke);
    }
    if (_brushDries(stroke.brushType)) {
      _runDryingAnimation(stroke);
    } else {
      stroke.tailFactor = 1.0;
    }
    notifyListeners();
  }

  bool _brushDries(BrushType type) =>
      type == BrushType.pen ||
      type == BrushType.arrow ||
      type == BrushType.eraser;

  /// Removes the newest committed stroke.
  void undo() {
    if (strokes.isEmpty) return;
    strokes.removeLast();
    notifyListeners();
  }

  void _resetVelocityTracking() {
    _previousPosition = null;
    _previousTimestampMs = 0;
    _previousVelocity = 0;
    _previousWidth = 0;
    _lastInputMs = 0;
  }

  late final Animator<double> _arrowAnimator = Animator<double>(
    getter: () => _animatingStroke?.arrowProgress ?? 1.0,
    setter: (v) {
      _animatingStroke?.arrowProgress = v;
      notifyListeners();
    },
    curve: Curves.easeInOut,
  )..disposeBy(this);
  Stroke? _animatingStroke;

  void _runArrowAnimation(Stroke stroke) {
    _animatingStroke = stroke;
    stroke.arrowProgress = 0;
    _arrowAnimator
        .animate(
          target: 1.0,
          duration: const Duration(milliseconds: 200),
        )
        .then((_) => _animatingStroke = null);
  }

  late final Animator<double> _dryingAnimator = Animator<double>(
    getter: () => _dryingStroke?.tailFactor ?? 1.0,
    setter: (v) {
      _dryingStroke?.tailFactor = v;
      notifyListeners();
    },
    curve: Curves.easeOut,
  )..disposeBy(this);
  Stroke? _dryingStroke;

  void _runDryingAnimation(Stroke stroke) {
    _dryingStroke = stroke;
    _dryingAnimator
        .animate(
          target: 1.0,
          duration: const Duration(milliseconds: 400),
        )
        .then((_) => _dryingStroke = null);
  }

  /// Telegram's `renderArrowLength = max(minRenderArrowLength, lineWidth * 3)`
  /// where `minRenderArrowLength = max(10, max(W,H) * 0.02)`
  /// (`DrawingPenTool.swift:308, 312`). Lookback walks back through the
  /// stored points until distance to end > arrowLength * 0.5
  /// (`DrawingPenTool.swift:370-378`).
  double _arrowArmLength(double thickness) {
    final maxDim = math.max(imageSize.width, imageSize.height);
    final minArm = math.max(10.0, maxDim * 0.02);
    return math.max(minArm, thickness * 3);
  }

  void _computeArrowAnchor(Stroke stroke) {
    if (stroke.points.length < 2) return;
    final endPos = stroke.points.last.position;
    final lookback = _arrowArmLength(stroke.thickness) * 0.5;
    Offset startPos = stroke.points[stroke.points.length - 2].position;
    for (var i = stroke.points.length - 2; i >= 0; i--) {
      if ((stroke.points[i].position - endPos).distance > lookback) {
        startPos = stroke.points[i].position;
        break;
      }
    }
    stroke.arrowAnchor = endPos;
    stroke.arrowDirection = math.atan2(
      startPos.dy - endPos.dy,
      startPos.dx - endPos.dx,
    );
  }

  @override
  Size get exportSize => imageSize;

  @override
  void paintExport(Canvas canvas, Size size) {
    _settleAnimations();
    canvas.drawImage(image, Offset.zero, Paint());
    _paintStrokesIntoCanvas(canvas, size);
  }

  /// Paint just the buffered strokes — no source image. Used by the
  /// compose-pipeline composer ([ComposeEntry._composeLayers]) when an
  /// upstream stage has already painted the image; we want to
  /// stack strokes on top without redrawing the source. Strokes are
  /// in source-space coordinates so they line up with whatever the
  /// upstream painted at the same dims.
  void paintStrokesOnly(Canvas canvas, Size size) {
    _settleAnimations();
    _paintStrokesIntoCanvas(canvas, size);
  }

  /// Paint source image + all strokes (committed + in-flight) at the
  /// current canvas origin. Caller has set up the canvas transform
  /// (e.g. camera + image-space ops); we just deposit our content.
  /// Used by both the layer's own [paintViewport] and by composed-scene
  /// painters that render the source × strokes pipeline inside a crop
  /// transform.
  void paintSourceAndStrokes(Canvas canvas) {
    canvas.drawImage(image, Offset.zero, Paint());
    canvas.saveLayer(Offset.zero & imageSize, Paint());
    for (var i = 0; i < strokes.length; i++) {
      final s = strokes[i];
      _paintStroke(
        canvas,
        s.points,
        s.brushType,
        _strokeColorFor(s, i),
        s.thickness,
        stroke: s,
        tailFactor: s.tailFactor,
      );
    }
    if (currentPoints.isNotEmpty) {
      _paintStroke(
        canvas,
        currentPoints,
        currentBrush,
        currentColor,
        _brushThicknessImageSpace,
        tailFactor: _activeWidthFactor,
      );
    }
    canvas.restore();
  }

  void _paintStrokesIntoCanvas(Canvas canvas, Size size) {
    canvas.saveLayer(Offset.zero & size, Paint());
    for (var i = 0; i < strokes.length; i++) {
      final s = strokes[i];
      _paintStroke(
        canvas,
        s.points,
        s.brushType,
        _strokeColorFor(s, i),
        s.thickness,
        stroke: s,
      );
    }
    canvas.restore();
  }

  /// Faded color for stroke at [index]: full alpha for strokes already
  /// present at last [saveSnapshot]; multiplied by [_fadeNewStrokes]
  /// for strokes added during the current session (so they fade out
  /// smoothly on [restoreSnapshotAnimated]).
  Color _strokeColorFor(Stroke s, int index) {
    if (_fadeNewStrokes >= 1.0 || index < _snapshotStrokeCount) return s.color;
    return s.color.withValues(alpha: s.color.a * _fadeNewStrokes);
  }

  /// Cancel any in-flight drying / arrow animation and snap every stroke
  /// to its fully-committed shape (tail factor 1.0, arrow progress 1.0).
  void completeAnimations() {
    _settleAnimations();
    notifyListeners();
  }

  /// Same as [completeAnimations] but without the notify — safe to call
  /// from inside [paintExport] (Flutter forbids `markNeedsPaint`-equivalent
  /// notifications during paint).
  void _settleAnimations() {
    _dryingAnimator.cancel();
    _arrowAnimator.cancel();
    for (final s in strokes) {
      s.tailFactor = 1.0;
      if (s.isArrow) s.arrowProgress = 1.0;
    }
    _dryingStroke = null;
    _animatingStroke = null;
  }

  @override
  void paintViewport(Canvas canvas, Size size,
      {required vmath.Matrix4 camera}) {
    canvas.save();
    canvas.transform(camera.storage);
    paintSourceAndStrokes(canvas);
    canvas.restore();
  }

  // ─── Brush dispatch ─────────────────────────────────────────────────

  void _paintStroke(
    Canvas canvas,
    List<StrokePoint> points,
    BrushType type,
    Color color,
    double thickness, {
    Stroke? stroke,
    double tailFactor = 1.0,
  }) {
    if (points.isEmpty) return;
    if (points.length == 1) {
      _paintDot(canvas, points.first, type, color, thickness);
      return;
    }
    switch (type) {
      case BrushType.pen:
        _paintTaperedFill(canvas, points, color, thickness,
            tailFactor: tailFactor);
      case BrushType.arrow:
        _paintTaperedFill(canvas, points, color, thickness,
            tailFactor: tailFactor);
        if (stroke != null && stroke.isArrow) {
          _paintArrowHead(canvas, stroke);
        }
      case BrushType.marker:
        _paintMarker(canvas, points, color, thickness);
      case BrushType.neon:
        _paintNeon(canvas, points, color, thickness);
      case BrushType.eraser:
        _paintTaperedFill(
          canvas,
          points,
          const Color(0xFFFFFFFF),
          thickness,
          blend: BlendMode.clear,
          tailFactor: tailFactor,
        );
    }
  }

  void _paintDot(
    Canvas canvas,
    StrokePoint p,
    BrushType type,
    Color color,
    double thickness,
  ) {
    switch (type) {
      case BrushType.pen:
      case BrushType.arrow:
      case BrushType.marker:
        canvas.drawCircle(p.position, thickness * 0.5, Paint()..color = color);
      case BrushType.neon:
        _paintNeonDot(canvas, p.position, color, thickness);
      case BrushType.eraser:
        canvas.drawCircle(
          p.position,
          thickness * 0.5,
          Paint()
            ..color = const Color(0xFFFFFFFF)
            ..blendMode = BlendMode.clear,
        );
    }
  }

  // ─── Pen / eraser tapered fill ──────────────────────────────────────

  /// Fill the stroke as a single path so the eraser's [BlendMode.clear]
  /// applies uniformly across the whole stroke instead of leaving seams
  /// at segment joins.
  void _paintTaperedFill(
    Canvas canvas,
    List<StrokePoint> points,
    Color color,
    double thickness, {
    BlendMode? blend,
    double tailFactor = 1.0,
  }) {
    final path = _buildTaperedPath(points, thickness, tailFactor: tailFactor);
    if (path == null) return;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    if (blend != null) paint.blendMode = blend;
    canvas.drawPath(path, paint);
  }

  /// Telegram's `activeWidthFactor` for the un-finalized live tail of a
  /// stroke (`DrawingPenTool.swift:6`). Applied with a smooth ramp over
  /// the last [_activeTailLen] smooth points so the tip is thinner while
  /// the user is still drawing and grows back to full width as new points
  /// commit further down the stroke.
  static const double _activeWidthFactor = 0.7;
  static const int _activeTailLen = 8;

  /// Build the stroke as a union of trapezoids (between consecutive
  /// smoothed points, with widths interpolated from each endpoint) and
  /// circular caps at every smoothed point. Mirrors telegram's per-segment
  /// geometry in `DrawingPenTool.swift:739-874`.
  Path? _buildTaperedPath(
    List<StrokePoint> points,
    double thickness, {
    double tailFactor = 1.0,
  }) {
    final smooth = _resamplePoints(points);
    if (smooth.length < 2) return null;

    final widths = <double>[];
    for (var i = 0; i < smooth.length; i++) {
      var w = smooth[i].width > 0 ? smooth[i].width : thickness;
      final fromEnd = smooth.length - 1 - i;
      if (tailFactor < 1.0 && fromEnd < _activeTailLen) {
        final t = fromEnd / _activeTailLen;
        w *= tailFactor + (1.0 - tailFactor) * t;
      }
      widths.add(math.max(w, thickness * 0.08));
    }

    final path = Path();

    for (var i = 0; i < smooth.length - 1; i++) {
      final p1 = smooth[i].position;
      final p2 = smooth[i + 1].position;
      final dir = p2 - p1;
      final dirLen = dir.distance;
      if (dirLen == 0) continue;
      final perpX = -dir.dy / dirLen;
      final perpY = dir.dx / dirLen;
      final w1 = widths[i] / 2;
      final w2 = widths[i + 1] / 2;
      path
        ..moveTo(p1.dx + perpX * w1, p1.dy + perpY * w1)
        ..lineTo(p1.dx - perpX * w1, p1.dy - perpY * w1)
        ..lineTo(p2.dx - perpX * w2, p2.dy - perpY * w2)
        ..lineTo(p2.dx + perpX * w2, p2.dy + perpY * w2)
        ..close();
    }

    for (var i = 0; i < smooth.length; i++) {
      path.addOval(
        Rect.fromCircle(center: smooth[i].position, radius: widths[i] / 2),
      );
    }

    return path;
  }

  /// Cubic Catmull-Rom resample expressed as cubic Bezier samples. Picks
  /// 24..48 samples per input segment based on segment length so curvy
  /// stretches stay smooth without exploding the vertex count on long
  /// straight runs. Width is interpolated along the same bezier so
  /// neighbouring smoothed points have continuously varying widths
  /// (matches telegram's per-channel bezier in `DrawingPenTool.swift:684-705`).
  List<StrokePoint> _resamplePoints(List<StrokePoint> points) {
    if (points.length < 4) return points;
    const segPx = 6.0;
    final out = <StrokePoint>[];
    for (var i = 0; i < points.length - 3; i++) {
      final p0 = points[i];
      final p1 = points[i + 1];
      final p2 = points[i + 2];
      final p3 = points[i + 3];
      final segDist = (p2.position - p1.position).distance;
      final segments = math.min(48, math.max((segDist / segPx).floor(), 24));
      final step = 1.0 / segments;
      for (var t = 0.0; t < 1.0; t += step) {
        final pos = _cubicBezier(
            p0.position, p1.position, p2.position, p3.position, t);
        final v = p0.velocity + (p3.velocity - p0.velocity) * t;
        final w = _cubicBezierScalar(p0.width, p1.width, p2.width, p3.width, t);
        out.add(StrokePoint(position: pos, velocity: v, width: w));
      }
    }
    if (out.isEmpty) return points;
    out.add(points.last);
    return out;
  }

  Offset _cubicBezier(Offset a, Offset c1, Offset c2, Offset b, double t) {
    final t1 = 1 - t;
    final tt = t * t;
    final ttt = tt * t;
    final t11 = t1 * t1;
    final t111 = t11 * t1;
    return Offset(
      t111 * a.dx + 3 * t11 * t * c1.dx + 3 * t1 * tt * c2.dx + ttt * b.dx,
      t111 * a.dy + 3 * t11 * t * c1.dy + 3 * t1 * tt * c2.dy + ttt * b.dy,
    );
  }

  double _cubicBezierScalar(double a, double c1, double c2, double b, double t) {
    final t1 = 1 - t;
    final tt = t * t;
    final ttt = tt * t;
    final t11 = t1 * t1;
    final t111 = t11 * t1;
    return t111 * a + 3 * t11 * t * c1 + 3 * t1 * tt * c2 + ttt * b;
  }

  // ─── Marker ──────────────────────────────────────────────────────────

  void _paintMarker(
    Canvas canvas,
    List<StrokePoint> points,
    Color color,
    double thickness,
  ) {
    final path = _smoothCenterPath(points);
    final paint = Paint()
      ..color = color.withValues(alpha: color.a * 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, paint);
  }

  // ─── Neon ────────────────────────────────────────────────────────────

  /// Telegram's `renderShadowRadius = min(W,H) * 0.02` and
  /// `renderStrokeWidth = min(W,H) * 0.008` (`DrawingNeonTool.swift:181-203`).
  /// Both are image-space, NOT relative to the brush thickness.
  ({double shadow, double border}) _neonRenderConstants() {
    final minDim = math.min(imageSize.width, imageSize.height);
    return (shadow: minDim * 0.02, border: minDim * 0.008);
  }

  void _paintNeon(
    Canvas canvas,
    List<StrokePoint> points,
    Color color,
    double thickness,
  ) {
    final path = _smoothCenterPath(points);
    final (fill, glow) = _neonColors(color);
    final c = _neonRenderConstants();

    canvas.saveLayer(
      null,
      Paint()
        ..colorFilter =
            ColorFilter.mode(glow.withValues(alpha: 0.87), BlendMode.srcIn),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = fill
        ..style = PaintingStyle.stroke
        ..strokeWidth = thickness * 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, c.shadow * 1.9),
    );
    canvas.restore();

    final border = Color.lerp(fill, glow, 0.25)!;
    canvas.drawPath(
      path,
      Paint()
        ..color = border
        ..style = PaintingStyle.stroke
        ..strokeWidth = c.border
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = fill
        ..style = PaintingStyle.stroke
        ..strokeWidth = thickness
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  void _paintNeonDot(
    Canvas canvas,
    Offset center,
    Color color,
    double thickness,
  ) {
    final (fill, glow) = _neonColors(color);
    final c = _neonRenderConstants();
    canvas.saveLayer(
      null,
      Paint()
        ..colorFilter =
            ColorFilter.mode(glow.withValues(alpha: 0.87), BlendMode.srcIn),
    );
    canvas.drawCircle(
      center,
      thickness,
      Paint()
        ..color = fill
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, c.shadow * 1.9),
    );
    canvas.restore();
    canvas.drawCircle(center, thickness * 0.5, Paint()..color = fill);
  }

  /// Neon's white-core / colored-glow trick: when the user picks a
  /// near-black, the core flips to the picked color so the stroke is
  /// still visible, and the glow becomes purple to keep the neon vibe.
  (Color fill, Color glow) _neonColors(Color color) {
    final hsl = HSLColor.fromColor(color);
    if (hsl.lightness < 0.01) {
      return (color, const Color(0xFF440881));
    }
    return (const Color(0xFFFFFFFF), color);
  }

  Path _smoothCenterPath(List<StrokePoint> points) {
    final p = Path();
    if (points.isEmpty) return p;
    if (points.length == 1) {
      p.moveTo(points[0].position.dx, points[0].position.dy);
      return p;
    }
    p.moveTo(points[0].position.dx, points[0].position.dy);
    for (var i = 0; i < points.length - 1; i++) {
      final p0 = points[math.max(0, i - 1)].position;
      final p1 = points[i].position;
      final p2 = points[i + 1].position;
      final p3 = points[math.min(points.length - 1, i + 2)].position;
      final c1 = Offset(
        p1.dx + (p2.dx - p0.dx) / 6,
        p1.dy + (p2.dy - p0.dy) / 6,
      );
      final c2 = Offset(
        p2.dx - (p3.dx - p1.dx) / 6,
        p2.dy - (p3.dy - p1.dy) / 6,
      );
      p.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
    }
    return p;
  }

  // ─── Arrow head ─────────────────────────────────────────────────────

  void _paintArrowHead(Canvas canvas, Stroke stroke) {
    final anchor = stroke.arrowAnchor;
    final dir = stroke.arrowDirection;
    final progress = stroke.arrowProgress;
    if (anchor == null || dir == null || progress <= 0) return;

    final len = _arrowArmLength(stroke.thickness);
    final lastPoint = stroke.points.isNotEmpty ? stroke.points.last : null;
    final lastWidth = lastPoint != null && lastPoint.width > 0
        ? lastPoint.width
        : stroke.thickness;
    final lineW = math.max(lastWidth * 0.75, stroke.thickness * 0.2 * 1.8);

    final leftEnd = Offset(
      anchor.dx + len * math.cos(dir - 0.45),
      anchor.dy + len * math.sin(dir - 0.45),
    );
    final rightEnd = Offset(
      anchor.dx + len * math.cos(dir + 0.45),
      anchor.dy + len * math.sin(dir + 0.45),
    );
    final left = Offset.lerp(anchor, leftEnd, progress)!;
    final right = Offset.lerp(anchor, rightEnd, progress)!;

    final paint = Paint()
      ..color = stroke.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = lineW
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(anchor, left, paint);
    canvas.drawLine(anchor, right, paint);
  }
}

/// Map a viewport-space pointer position into source-image space: undo the
/// user's [viewerCamera] pan/zoom, then invert the cropped-view transform
/// when [crop] has applied edits, else the plain [hostCamera] fit.
Offset toSourcePoint(
  Offset viewport, {
  required vmath.Matrix4 hostCamera,
  vmath.Matrix4? viewerCamera,
  CropImageLayer? crop,
}) {
  var v = viewport;
  if (viewerCamera != null) {
    final inv = vmath.Matrix4.copy(viewerCamera)..invert();
    final vec = vmath.Vector3(v.dx, v.dy, 0)..applyMatrix4(inv);
    v = Offset(vec.x, vec.y);
  }
  if (crop != null && crop.hasAppliedEdits) {
    return crop.viewportToSource(v, camera: hostCamera);
  }
  return DrawImageLayer.toImageSpace(v, hostCamera);
}

/// Rotation and scale for a new text overlay so it appears upright at
/// viewport-native size through the draw editor's view transform
/// (viewer pan/zoom × crop imageTransform).
({double rotation, double scale}) textEntityViewPose({
  vmath.Matrix4? viewerCamera,
  CropImageLayer? crop,
}) {
  var scale = 1.0;
  var rotation = 0.0;
  final viewer = viewerCamera?.storage[0] ?? 1.0;
  if (viewer.abs() > 1e-9) scale /= viewer.abs();
  if (crop != null && crop.hasAppliedEdits) {
    final t = crop.imageTransform;
    if (t.totalScale.abs() > 1e-9) scale /= t.totalScale.abs();
    rotation = -t.totalRotate;
  }
  return (rotation: rotation, scale: scale);
}

/// One- or two-finger gesture surface for the draw editor.
///
/// - **1 finger**: draw a stroke (beginStroke / addPoint / endStroke).
/// - **2 fingers**: drop the in-flight stroke and pan + scale the
///   `viewerCamera` (screen-space transform stacked on top of the
///   editor's base camera). Once the gesture goes multi-touch we stay
///   in pan/zoom mode until ALL fingers lift — matches telegram's
///   editor behaviour. New strokes require a fresh single-finger
///   gesture.
///
/// When [crop] has applied edits, viewport pointer coords are inverted
/// through the cropped-view transform (host camera + crop's imageTransform)
/// AND through [viewerCamera] so strokes land at the right source pixel.
class DrawGestures extends StatefulWidget {
  /// Draws into [layer] as [hostCamera] shows it.
  const DrawGestures({
    super.key,
    required this.layer,
    required this.hostCamera,
    this.crop,
    this.viewerCamera,
  });

  /// The layer strokes are drawn into.
  final DrawImageLayer layer;
  /// The host's image-to-viewport transform.
  final ValueListenable<vmath.Matrix4> hostCamera;
  /// The crop the scene is shown through.
  final CropImageLayer? crop;

  /// Screen-space transform stacked on top of the base camera. The
  /// painter applies it; the gesture system mutates it on two-finger
  /// pinch/pan. Null disables the pan/zoom mode and gestures stay in
  /// "drawing only" behaviour.
  final ValueNotifier<vmath.Matrix4>? viewerCamera;

  @override
  State<DrawGestures> createState() => _DrawGesturesState();
}

enum _DrawGestureMode { drawing, panning }

class _DrawGesturesState extends State<DrawGestures> {
  /// Monotonic counter of drawing sessions. Increments each time
  /// pointers transition from 0 to ≥1 (a fresh user gesture starts).
  /// Restarts *within* a session (e.g. 1 → 2 fingers as Flutter's
  /// `ScaleGestureRecognizer` re-emits start/end on pointer count
  /// changes) do NOT advance the counter — the counter only moves on
  /// real session boundaries, which matches how the user thinks about
  /// drawings ("each time I put my finger down, that's a new stroke").
  /// Exposed via [iteration] for tests / debug.
  int _iteration = 0;

  /// Public read-only view of the gesture-session counter. Tests use
  /// this to assert that a 1-finger → 2-finger → 1-finger transition
  /// is a single session (one bump), while two distinct pointer-down
  /// events (lift then re-touch) are two sessions (two bumps).
  int get iteration => _iteration;

  _DrawGestureMode? _mode;
  vmath.Matrix4 _gestureStartCamera = vmath.Matrix4.identity();
  Offset _gestureStartFocal = Offset.zero;

  bool get _inSession => _mode != null;

  Offset _toSource(Offset viewport) => toSourcePoint(
    viewport,
    hostCamera: widget.hostCamera.value,
    viewerCamera: widget.viewerCamera?.value,
    crop: widget.crop,
  );

  void _resetGestureOrigin(Offset focal) {
    _gestureStartFocal = focal;
    final viewer = widget.viewerCamera;
    _gestureStartCamera = viewer != null
        ? vmath.Matrix4.copy(viewer.value)
        : vmath.Matrix4.identity();
  }

  double _hostCameraScale() => widget.hostCamera.value.storage[0];

  void _onScaleStart(ScaleStartDetails e) {
    if (!_inSession) {
      // A new drawing iteration: the user just placed a finger down
      // and we weren't tracking any prior gesture. Decide drawing vs
      // panning based on the initial pointer count.
      _iteration++;
      if (e.pointerCount == 1) {
        _mode = _DrawGestureMode.drawing;
        widget.layer.beginStroke(
          _toSource(e.localFocalPoint),
          cameraScale: _hostCameraScale(),
        );
      } else {
        _mode = _DrawGestureMode.panning;
      }
    } else if (_mode == _DrawGestureMode.drawing && e.pointerCount >= 2) {
      // Mid-iteration restart: a second finger landed mid-stroke.
      // Same iteration (no counter advance) but we pivot to pan/zoom
      // for the rest of it — drop the in-flight stroke and stay in
      // panning until ALL fingers lift.
      widget.layer.cancelStroke();
      _mode = _DrawGestureMode.panning;
    }
    _resetGestureOrigin(e.localFocalPoint);
  }

  void _onScaleUpdate(ScaleUpdateDetails e) {
    if (_mode == _DrawGestureMode.drawing) {
      widget.layer.addPoint(_toSource(e.localFocalPoint));
      return;
    }
    if (_mode != _DrawGestureMode.panning) return;

    final viewer = widget.viewerCamera;
    if (viewer == null) return;
    final delta = e.localFocalPoint - _gestureStartFocal;
    final scale = e.scale.clamp(_kMinViewerScale, _kMaxViewerScale);
    final pivot = _gestureStartFocal;

    // newCamera = T(delta) · T(pivot) · S(scale) · T(-pivot) · startCamera
    final pivotScale = vmath.Matrix4.identity()
      ..translateByDouble(pivot.dx, pivot.dy, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1)
      ..translateByDouble(-pivot.dx, -pivot.dy, 0, 1);
    final pan = vmath.Matrix4.identity()
      ..translateByDouble(delta.dx, delta.dy, 0, 1);
    viewer.value = pan.multiplied(pivotScale.multiplied(_gestureStartCamera));
  }

  void _onScaleEnd(ScaleEndDetails e) {
    if (e.pointerCount > 0) {
      // Restart in progress — the recognizer will fire `onScaleStart`
      // immediately with the new pointer count. Same iteration; don't
      // reset state here.
      return;
    }
    // True session end: all fingers up. Commit if drawing; reset mode.
    // The iteration counter holds its value — the next pointer-down
    // will advance it.
    if (_mode == _DrawGestureMode.drawing) widget.layer.endStroke();
    _mode = null;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onScaleStart: _onScaleStart,
      onScaleUpdate: _onScaleUpdate,
      onScaleEnd: _onScaleEnd,
    );
  }
}

/// Scale clamps for the draw editor's user pan/zoom. 1.0 = fit
/// (camera at base state); 4.0 lets the user zoom in 4× for stroke
/// precision. Pinch-out below 1.0 is suppressed so the editor never
/// shrinks the canvas smaller than the viewport-fit baseline.
const double _kMinViewerScale = 1.0;
const double _kMaxViewerScale = 4.0;
