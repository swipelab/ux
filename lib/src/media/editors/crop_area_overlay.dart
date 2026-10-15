import 'package:ux/src/media/editors/crop_image_layer.dart';
import 'package:ux/src/media/editors/crop_rotation_dial.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:vector_math/vector_math_64.dart' as vmath;

/// Telegram's draggable crop-area handles (`TGPhotoCropAreaView` +
/// `TGPhotoCropControl`): four 44pt corner controls centered ON the
/// crop corners and four 44pt-thick edge strips between them, each
/// with 16pt of extra hit slop except below `crop.bottom`, where the
/// bottom edge and corners stop at [kCropDialHandleReach] so the dial
/// owns the rest of the gutter. All hit-opaque (TG's exclusiveTouch —
/// a drag that starts on a handle never reaches the pinch surface).
///
/// Dragging rewrites [CropImageLayer.crop] in image-space through the
/// host camera. The content stays screen-fixed by construction (the
/// camera doesn't move during a drag), and every update snaps the
/// image transform to coverage — telegram's live, non-animated
/// `fitContentInsideBoundsAllowScale`. Releasing arms the layer's 1s
/// confirm countdown; the confirm re-fits the host camera (the
/// evenlyFill refit) via [CropImageLayer.confirmTick].
///
/// A 2px white highlight marks the dragged edge; all four show while
/// the aspect ratio is locked (TG `setLockAspectRatio`).
class CropAreaOverlay extends StatefulWidget {
  /// Draws and drags the crop of [layer] as [hostCamera] shows it.
  const CropAreaOverlay({
    super.key,
    required this.layer,
    required this.hostCamera,
  });

  /// The layer whose crop is dragged.
  final CropImageLayer layer;

  /// The image-to-screen transform the drag is read through.
  final ValueListenable<vmath.Matrix4> hostCamera;

  @override
  State<CropAreaOverlay> createState() => _CropAreaOverlayState();
}

/// Claims the pointer at touch-down — telegram's `exclusiveTouch` on
/// `TGPhotoCropControl`. Without the eager claim the stack's 40px
/// edge-swipe strip (hit-tested above the screen content) wins the
/// arena for horizontal drags, so grabbing the LEFT handles triggered
/// swipe-back instead of a resize. Tracking also starts from the very
/// first pixel (no slop), matching telegram's control feel.
class _HandleDragRecognizer extends PanGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

enum _Handle {
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
  top,
  left,
  bottom,
  right;

  bool get isEdge =>
      this == top || this == left || this == bottom || this == right;
}

/// TGPhotoCropCornerControlSize / TGPhotoCropEdgeControlSize.
const double _kControlSize = 44;

/// TG hitTestEdgeInsets on every control.
const double _kHitSlop = 16;

const double _kHighlightThickness = 2;

class _CropAreaOverlayState extends State<CropAreaOverlay> {
  _Handle? _active;

  /// Handles whose drag began while another surface owned the
  /// interaction (a pinch in progress, or another handle already
  /// tracking) — their whole gesture is dropped, telegram's
  /// `shouldBeginEditing` false + `exclusiveTouch` between controls.
  final Set<_Handle> _suppressed = <_Handle>{};

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
    super.dispose();
  }

  void _relayout() {
    if (mounted) setState(() {});
  }

  double get _scale => widget.hostCamera.value.storage[0];

  /// Crop rect in viewport coordinates (camera is scale + translate).
  Rect get _areaRect {
    final m = widget.hostCamera.value;
    final s = m.storage[0];
    final crop = widget.layer.crop;
    return Rect.fromLTWH(
      crop.left * s + m.storage[12],
      crop.top * s + m.storage[13],
      crop.width * s,
      crop.height * s,
    );
  }

  void _begin(_Handle handle) {
    if (_active != null ||
        widget.layer.scrollTracking ||
        widget.layer.dialTracking) {
      _suppressed.add(handle);
      return;
    }
    _active = handle;
    widget.layer.areaTracking = true;
    widget.layer.beginInteraction(instantBackdrop: true);
    setState(() {});
  }

  void _end(_Handle handle) {
    if (_suppressed.remove(handle)) return;
    if (_active != handle) return;
    _active = null;
    widget.layer.areaTracking = false;
    widget.layer.endInteraction();
    setState(() {});
  }

  void _drag(_Handle handle, Offset t, Rect bounds) {
    if (_suppressed.contains(handle) || _active != handle) return;
    final layer = widget.layer;
    final lock = layer.lockedAspectRatio;
    var r = _areaRect;

    // TGPhotoCropAreaView.handleResizeWithSender — per-control rect
    // arithmetic; when locked, the dominant translation axis picks
    // whether width or height leads.
    switch (handle) {
      case _Handle.topLeft:
        r = Rect.fromLTWH(
          r.left + t.dx,
          r.top + t.dy,
          r.width - t.dx,
          r.height - t.dy,
        );
        if (lock != null) {
          var c = t.dx.abs() < t.dy.abs()
              ? _withHeight(r, lock)
              : _withWidth(r, lock);
          c = c.translate(-(c.width - r.width), -(c.height - r.height));
          r = c;
        }
      case _Handle.topRight:
        r = Rect.fromLTWH(
          r.left,
          r.top + t.dy,
          r.width + t.dx,
          r.height - t.dy,
        );
        if (lock != null) {
          var c = t.dx.abs() < t.dy.abs()
              ? _withHeight(r, lock)
              : _withWidth(r, lock);
          c = c.translate(0, -(c.height - r.height));
          r = c;
        }
      case _Handle.bottomLeft:
        r = Rect.fromLTWH(
          r.left + t.dx,
          r.top,
          r.width - t.dx,
          r.height + t.dy,
        );
        if (lock != null) {
          var c = t.dx.abs() < t.dy.abs()
              ? _withHeight(r, lock)
              : _withWidth(r, lock);
          c = c.translate(-(c.width - r.width), 0);
          r = c;
        }
      case _Handle.bottomRight:
        r = Rect.fromLTWH(r.left, r.top, r.width + t.dx, r.height + t.dy);
        if (lock != null) {
          r = t.dx.abs() < t.dy.abs()
              ? _withHeight(r, lock)
              : _withWidth(r, lock);
        }
      case _Handle.top:
        r = Rect.fromLTWH(r.left, r.top + t.dy, r.width, r.height - t.dy);
        if (lock != null) r = _withHeight(r, lock);
      case _Handle.left:
        r = Rect.fromLTWH(r.left + t.dx, r.top, r.width - t.dx, r.height);
        if (lock != null) r = _withWidth(r, lock);
      case _Handle.bottom:
        r = Rect.fromLTWH(r.left, r.top, r.width, r.height + t.dy);
        if (lock != null) r = _withHeight(r, lock);
      case _Handle.right:
        r = Rect.fromLTWH(r.left, r.top, r.width + t.dx, r.height);
        if (lock != null) r = _withWidth(r, lock);
    }

    if (r.width < _kControlSize) {
      r = Rect.fromLTWH(r.left, r.top, _kControlSize, r.height);
    }
    if (r.height < _kControlSize) {
      r = Rect.fromLTWH(r.left, r.top, r.width, _kControlSize);
    }
    if (lock != null) {
      if (lock > 1) {
        if (r.width <= _kControlSize) {
          r = Rect.fromLTWH(r.left, r.top, _kControlSize, _kControlSize * lock);
        }
      } else {
        if (r.height <= _kControlSize) {
          r = Rect.fromLTWH(r.left, r.top, _kControlSize / lock, _kControlSize);
        }
      }
    }

    r = _capped(r, bounds, lock);

    final m = widget.hostCamera.value;
    final s = m.storage[0];
    if (s.abs() < 1e-9) return;
    layer.crop = Rect.fromLTWH(
      (r.left - m.storage[12]) / s,
      (r.top - m.storage[13]) / s,
      r.width / s,
      r.height / s,
    );
    layer.cropChangedSinceConfirm = true;
    // update() inside the snap notifies the transform, which the layer
    // mirrors into its own notification — the repaint rides along.
    layer.snapToCoverage();
  }

  static Rect _withWidth(Rect r, double aspect) =>
      Rect.fromLTWH(r.left, r.top, r.width, r.width * aspect);

  static Rect _withHeight(Rect r, double aspect) =>
      Rect.fromLTWH(r.left, r.top, r.height / aspect, r.height);

  /// TGPhotoCropView._cappedAreaViewRectWithRect — keep the area
  /// inside [bounds], preserving the lock.
  static Rect _capped(Rect r, Rect bounds, double? lock) {
    var left = r.left, top = r.top, w = r.width, h = r.height;

    if (left + w > bounds.right) {
      left = left
          .clamp(double.negativeInfinity, bounds.right - _kControlSize)
          .toDouble();
      w = (bounds.right - left)
          .clamp(_kControlSize, double.infinity)
          .toDouble();
      if (lock != null) h = w * lock;
    } else if (left < bounds.left) {
      w = left + w - bounds.left;
      if (lock != null) h = w * lock;
      left = bounds.left;
    }

    if (top + h > bounds.bottom) {
      top = top
          .clamp(double.negativeInfinity, bounds.bottom - _kControlSize)
          .toDouble();
      h = (bounds.bottom - top)
          .clamp(_kControlSize, double.infinity)
          .toDouble();
      if (lock != null) w = h / lock;
    } else if (top < bounds.top) {
      h = top + h - bounds.top;
      if (lock != null) w = h / lock;
      top = bounds.top;
    }

    return Rect.fromLTWH(left, top, w, h);
  }

  Widget _control(_Handle handle, Rect region, Rect bounds) {
    return Positioned(
      key: ValueKey(handle),
      left: region.left,
      top: region.top,
      width: region.width,
      height: region.height,
      child: RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: <Type, GestureRecognizerFactory>{
          _HandleDragRecognizer:
              GestureRecognizerFactoryWithHandlers<_HandleDragRecognizer>(
                _HandleDragRecognizer.new,
                (r) => r
                  ..onStart = ((_) => _begin(handle))
                  ..onUpdate = ((d) => _drag(handle, d.delta, bounds))
                  ..onEnd = ((_) => _end(handle))
                  ..onCancel = (() => _end(handle)),
              ),
        },
      ),
    );
  }

  /// Always mounted — the child list must stay structurally stable
  /// across rebuilds or a mid-drag rebuild re-matches the Positioned
  /// elements by index and disposes the active drag recognizer.
  /// Unlit highlights paint transparent instead of unmounting.
  Widget _highlight(_Handle edge, Rect line, bool lit) {
    return Positioned(
      key: ValueKey(('highlight', edge)),
      left: line.left,
      top: line.top,
      width: line.width,
      height: line.height,
      child: IgnorePointer(
        child: ColoredBox(
          color: lit ? const Color(0xFFFFFFFF) : const Color(0x00000000),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_scale.abs() < 1e-9) return SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final bounds = Offset.zero & constraints.biggest;
        final r = _areaRect;
        final reach = _kControlSize / 2 + _kHitSlop;
        final span = _kControlSize + 2 * _kHitSlop;
        final edgeW = (r.width - _kControlSize).clamp(0.0, double.infinity);
        final edgeH = (r.height - _kControlSize).clamp(0.0, double.infinity);

        final locked = widget.layer.lockedAspectRatio != null;
        bool lit(_Handle e) => locked || _active == e;

        return Stack(
          children: [
            _highlight(
              _Handle.top,
              Rect.fromLTWH(r.left, r.top - 1, r.width, _kHighlightThickness),
              lit(_Handle.top),
            ),
            _highlight(
              _Handle.bottom,
              Rect.fromLTWH(
                r.left,
                r.bottom - 1,
                r.width,
                _kHighlightThickness,
              ),
              lit(_Handle.bottom),
            ),
            _highlight(
              _Handle.left,
              Rect.fromLTWH(r.left - 1, r.top, _kHighlightThickness, r.height),
              lit(_Handle.left),
            ),
            _highlight(
              _Handle.right,
              Rect.fromLTWH(r.right - 1, r.top, _kHighlightThickness, r.height),
              lit(_Handle.right),
            ),

            // Edges first, corners after — corners win the overlaps.
            _control(
              _Handle.top,
              Rect.fromLTWH(
                r.left + _kControlSize / 2,
                r.top - reach,
                edgeW,
                span,
              ),
              bounds,
            ),
            _control(
              _Handle.bottom,
              Rect.fromLTWH(
                r.left + _kControlSize / 2,
                r.bottom - reach,
                edgeW,
                reach + kCropDialHandleReach,
              ),
              bounds,
            ),
            _control(
              _Handle.left,
              Rect.fromLTWH(
                r.left - reach,
                r.top + _kControlSize / 2,
                span,
                edgeH,
              ),
              bounds,
            ),
            _control(
              _Handle.right,
              Rect.fromLTWH(
                r.right - reach,
                r.top + _kControlSize / 2,
                span,
                edgeH,
              ),
              bounds,
            ),
            _control(
              _Handle.topLeft,
              Rect.fromCenter(center: r.topLeft, width: span, height: span),
              bounds,
            ),
            _control(
              _Handle.topRight,
              Rect.fromCenter(center: r.topRight, width: span, height: span),
              bounds,
            ),
            _control(
              _Handle.bottomLeft,
              Rect.fromLTRB(
                r.left - reach,
                r.bottom - reach,
                r.left + reach,
                r.bottom + kCropDialHandleReach,
              ),
              bounds,
            ),
            _control(
              _Handle.bottomRight,
              Rect.fromLTRB(
                r.right - reach,
                r.bottom - reach,
                r.right + reach,
                r.bottom + kCropDialHandleReach,
              ),
              bounds,
            ),
          ],
        );
      },
    );
  }
}
