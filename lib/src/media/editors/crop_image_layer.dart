import 'dart:async';
import 'dart:math' as dartmath;
import 'dart:ui' as ui;

import 'package:ux/src/media/design.dart';
import 'package:ux/src/media/editors/animator.dart';
import 'package:ux/src/media/editors/editor.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:ux/ux.dart';
import 'package:vector_math/vector_math_64.dart' as math;

/// Crop / rotate / flip tool layer.
///
/// Renders the image inside a crop rectangle with a corner-bracket frame
/// and a rule-of-thirds grid; pan + scale gestures (via [CropGestures])
/// reposition the image inside the fixed crop. The host wires
/// rotate-90 / flip / aspect-ratio buttons into the layer's mutators.
///
/// The viewport-fitting matrix lives on the host (`ComposeEntry`); the
/// layer is told the current camera at paint time and reads its scale
/// for grid-line widths. User gestures mutate [imageTransform] / [crop],
/// never the camera.
class CropImageLayer with Emitter, Painter, Exporter {
  /// Crops [image], which the caller owns.
  CropImageLayer({required this.image}) {
    imageTransform.subscribe(_onImageTransformChanged).disposeBy(this);
  }

  /// The source image.
  final ui.Image image;

  /// [image]'s size in pixels.
  late final Size imageSize = Size(
    image.width.toDouble(),
    image.height.toDouble(),
  );

  /// User-driven image-space transform: pan offset, scale, rotate, flip.
  /// Data state — tests and gestures observe synchronous changes here.
  late final UserTransform imageTransform = UserTransform();

  /// What paint actually draws. Mirrors [imageTransform] except while
  /// [_renderAnimator] is interpolating it across a button-driven
  /// rotate / reset / snapshot-restore — those snap [imageTransform]
  /// synchronously (so tests and gesture math see the new state) and
  /// run the visual change here over [kAnimation].
  ///
  /// `flipX` is mirrored directly even mid-animation: the card-flip is
  /// driven by [_flipDecoration] (a Y-axis tilt at paint time), not by
  /// interpolating flipX through zero.
  late final UserTransform _renderTransform = UserTransform();

  late final _renderAnimator = Animator<UserTransform>(
    getter: () => _renderTransform.clone(),
    setter: (e) {
      // flipX is governed by the data mirror, not by interpolation —
      // the card-flip plays out via [_flipDecoration] separately.
      final flipX = _renderTransform.flipX;
      _renderTransform.update(e);
      _renderTransform.flipX = flipX;
      notifyListeners();
    },
    curve: Curves.easeInOut,
  )..disposeBy(this);

  /// Generation of the current render-side spin. A dial grab bumps it
  /// so an interrupted spin does not restore the backdrop.
  int _renderSpin = 0;

  /// Hide the backdrop, animate the render transform to [target], and
  /// bring the backdrop back only if no newer spin took over.
  Future<void> _spin(
    UserTransform target, {
    Duration duration = kAnimation,
    Curve? curve,
  }) {
    final spin = ++_renderSpin;
    _hideBackdrop(animated: false);
    return _renderAnimator
        .animate(target: target, duration: duration, curve: curve)
        .then((_) {
          if (!disposed && spin == _renderSpin) _showBackdrop(animated: false);
        });
  }

  /// Y-axis tilt (radians) added on top of the data mirror during a
  /// flip transition. Starts at π — combined with the already-flipped
  /// data state this looks identical to the pre-flip image — and eases
  /// to 0, passing through π/2 (edge-on) so the user sees a card flip
  /// rather than a teleport.
  double _flipDecoration = 0;

  late final _flipAnimator = Animator<double>(
    getter: () => _flipDecoration,
    setter: (v) {
      _flipDecoration = v;
      notifyListeners();
    },
    curve: Curves.easeInOut,
  )..disposeBy(this);

  /// Suppresses the data→render mirror inside [_onImageTransformChanged]
  /// while a button mutator (rotate / restore / reset) is mid-mutation,
  /// so the render side can keep its pre-mutation value and animate
  /// from there.
  bool _suppressMirror = false;

  void _onImageTransformChanged() {
    // flipX always tracks the data state — the card-flip is a separate
    // decoration. Other fields mirror only when nothing is animating
    // them, so a button rotate/restore can hold the pre-state on render
    // while the animator interpolates it forward.
    _renderTransform.flipX = imageTransform.flipX;
    if (!_suppressMirror && !_renderAnimator.isAnimating) {
      final flipX = _renderTransform.flipX;
      _renderTransform.update(imageTransform);
      _renderTransform.flipX = flipX;
    }
    notifyListeners();
  }

  /// The angle paint draws at: the data angle at rest, the interpolated
  /// one while [_renderAnimator] runs.
  double get renderRotate => _renderTransform.totalRotate;

  /// Active crop rectangle in image-space. Defaults to the full image.
  late Rect crop = Offset.zero & imageSize;

  /// Aspect lock as height/width (telegram's `aspectRatio` shape), or
  /// null when the crop is free. Set by the aspect-ratio cycle; the
  /// handle overlay constrains resizes against it and shows all four
  /// edge highlights while locked.
  double? lockedAspectRatio;

  /// Set by the handle overlay on every area edit; consumed by the
  /// confirm countdown — the camera refit only runs when the crop
  /// rect actually changed (telegram's `_cropAreaChanged`).
  bool cropChangedSinceConfirm = false;

  /// Cross-surface interaction ownership, telegram's mutual gates
  /// (`TGPhotoCropView.shouldBeginChanging` / `shouldBeginEditing`):
  /// while one surface tracks the other two must not engage —
  /// otherwise a second finger pans the image mid-resize.
  bool areaTracking = false;

  /// Whether the pan and pinch surface tracks a gesture.
  bool scrollTracking = false;

  /// Whether the rotation dial tracks a gesture.
  bool dialTracking = false;

  /// Fires when a confirm lands (1s countdown after an area edit, or
  /// immediately on an aspect snap). `CropScreen` answers by
  /// re-fitting the host camera to the new crop rect — telegram's
  /// evenlyFill.
  late final ValueEmitter<int> confirmTick = ValueEmitter<int>(0)
    ..disposeBy(this);

  /// Instantly snap the image transform to the nearest crop-covering
  /// state — the live fit that runs on every handle-drag update
  /// (telegram's non-animated `fitContentInsideBoundsAllowScale`).
  void snapToCoverage() {
    _settleAnimator.cancel();
    imageTransform.update(_coveredTransform());
  }

  /// Telegram's confirm constraint (`performConfirmAnimated`): the
  /// crop rect may not demand more magnification than the zoom
  /// ceiling — each dimension stays ≥ source/10, repositioned to
  /// remain inside the image.
  void _constrainCropForConfirm() {
    final minW = imageSize.width / _maxZoomOverFill;
    final minH = imageSize.height / _maxZoomOverFill;
    if (crop.width >= minW && crop.height >= minH) return;
    var w = crop.width, h = crop.height;
    if (crop.width > crop.height) {
      w = dartmath.max(w, minW);
      h = crop.height * w / crop.width;
    } else {
      h = dartmath.max(h, minH);
      w = crop.width * h / crop.height;
    }
    var left = crop.left, top = crop.top;
    if (left + w > imageSize.width) left = imageSize.width - w;
    if (top + h > imageSize.height) top = imageSize.height - h;
    crop = Rect.fromLTWH(left, top, w, h);
  }

  /// Telegram's zoom ceiling: 10× the crop-rect fill scale
  /// (`TGPhotoCropScrollView.m:539` treats `maximumZoomScale` as
  /// relative to the fill-scale minimum).
  static const double _maxZoomOverFill = 10.0;

  /// totalScale at which the un-rotated image exactly fills [crop] —
  /// telegram's `minimumZoomScale`. Pinching below it rubber-bands.
  double get fillScale => dartmath.max(
    crop.width / imageSize.width,
    crop.height / imageSize.height,
  );

  /// Hard pinch ceiling for the current [crop].
  double get maxTotalScale => fillScale * _maxZoomOverFill;

  /// Smallest totalScale at which the image, rotated by [rotateZ],
  /// can still cover the whole crop rect: the crop rect's bounding
  /// box in the image-aligned frame must fit inside the source.
  double coverageScale(double rotateZ) {
    final c = dartmath.cos(rotateZ).abs();
    final s = dartmath.sin(rotateZ).abs();
    final w = crop.width * c + crop.height * s;
    final h = crop.width * s + crop.height * c;
    return dartmath.max(w / imageSize.width, h / imageSize.height);
  }

  /// The nearest transform to the current one at which the image
  /// fully covers [crop]: totalScale bumped to [coverageScale], then
  /// the offset clamped per-axis in the image-aligned frame
  /// (telegram's `fitContentInsideBoundsAllowScale`).
  UserTransform _coveredTransform() => _coveredAt(
    imageTransform.totalRotate,
    scaleFloor: imageTransform.totalScale,
  );

  /// [_coveredTransform] at an arbitrary [rotate], with [scaleFloor] as
  /// the smallest zoom the result may land on.
  UserTransform _coveredAt(double rotate, {required double scaleFloor}) {
    final t = imageTransform.clone();
    final delta = rotate - t.totalRotate;
    t
      ..scale = dartmath.max(scaleFloor, coverageScale(rotate))
      ..activeScale = 1
      ..rotateZ = rotate
      ..activeRotateZ = 0;
    _pivotOffsetAroundCrop(t, delta);

    final cx = imageSize.width / 2;
    final cy = imageSize.height / 2;
    final sr = math.Matrix4.identity()
      ..scaleByDouble(t.flipX * t.scale, t.scale, 1, 1)
      ..rotateZ(t.rotateZ);
    final srInv = math.Matrix4.copy(sr)..invert();

    var minX = double.infinity, minY = double.infinity;
    var maxX = -double.infinity, maxY = -double.infinity;
    for (final corner in [
      crop.topLeft,
      crop.topRight,
      crop.bottomRight,
      crop.bottomLeft,
    ]) {
      final q = srInv.transform3(
        math.Vector3(
          corner.dx - cx - t.offset.x,
          corner.dy - cy - t.offset.y,
          0,
        ),
      );
      minX = dartmath.min(minX, q.x);
      maxX = dartmath.max(maxX, q.x);
      minY = dartmath.min(minY, q.y);
      maxY = dartmath.max(maxY, q.y);
    }

    var dx = 0.0, dy = 0.0;
    if (minX < -cx) dx = -cx - minX;
    if (maxX + dx > cx) dx += cx - (maxX + dx);
    if (minY < -cy) dy = -cy - minY;
    if (maxY + dy > cy) dy += cy - (maxY + dy);

    if (dx != 0 || dy != 0) {
      t.offset = math.Vector3.copy(t.offset)
        ..sub(sr.transform3(math.Vector3(dx, dy, 0)));
    }
    return t;
  }

  late final _settleAnimator = Animator<UserTransform>(
    getter: () => imageTransform.clone(),
    setter: imageTransform.update,
    curve: const TgSpringCurve(),
  )..disposeBy(this);

  /// Spring the image back to the nearest crop-covering state —
  /// telegram's release fit (POP spring, speed 7 / bounciness 1).
  Future<void> settleToCoverage() =>
      _settleAnimator.animate(target: _coveredTransform(), duration: kTgSpring);

  double? _rotationScaleFloor;

  /// The zoom the rotation dial holds as it turns: the user's own last
  /// deliberate zoom, or [fillScale] when they have not set one.
  double get rotationScaleFloor => _rotationScaleFloor ?? fillScale;

  set rotationScaleFloor(double? value) => _rotationScaleFloor = value;

  /// Record the current zoom as the dial's floor, unless the image is
  /// already rotated and sitting at bare coverage — that zoom is the
  /// dial's own doing, not the user's.
  void captureRotationFloor() {
    final t = imageTransform;
    if (t.rotateZ == 0 || t.totalScale > coverageScale(t.totalRotate)) {
      rotationScaleFloor = t.totalScale;
    }
  }

  /// Set the free rotation angle and re-cover the crop in one commit,
  /// never zooming below [scaleFloor]. Takes over a running spin from
  /// wherever it had reached, so a dial grab mid-quarter-turn continues
  /// under the finger.
  void rotateCovered(double rotateZ, {required double scaleFloor}) {
    final spinning = _renderAnimator.isAnimating;
    _settleAnimator.cancel();
    _renderAnimator.cancel();
    _renderSpin++;
    if (spinning) {
      final flipX = imageTransform.flipX;
      imageTransform
        ..update(_renderTransform)
        ..flipX = flipX;
    }
    imageTransform.update(_coveredAt(rotateZ, scaleFloor: scaleFloor));
  }

  /// Opacity of the interior thirds lines. 0 at rest; fades to 1 over
  /// 0.2s while a gesture is live and back out 1.0s after it ends —
  /// telegram's grid show/hide + confirm-countdown timing
  /// (`TGPhotoCropView.m:542`, `TGPhotoCropGridView`).
  double gridOpacity = 0;

  static const Duration _gridFade = Duration(milliseconds: 200);
  static const Duration _confirmCountdown = Duration(seconds: 1);

  Timer? _gridFadeTimer;

  late final _gridAnimator = Animator<double>(
    getter: () => gridOpacity,
    setter: (v) {
      gridOpacity = v;
      notifyListeners();
    },
    curve: Curves.easeInOut,
  )..disposeBy(this);

  /// Opacity of the idle backdrop — the dark BLURRED rendition of the
  /// image outside the crop rect. 1 at rest; fades out over 0.16s
  /// when an interaction begins (instantly for handle drags, matching
  /// telegram's `resetBackdropViewsAnimated:false` on area edits) and
  /// back in when the confirm countdown lands
  /// (`TGPhotoCropView.showBackdropViewAnimated`).
  double backdropOpacity = 1;

  static const Duration _backdropFade = Duration(milliseconds: 160);

  late final _backdropAnimator = Animator<double>(
    getter: () => backdropOpacity,
    setter: (v) {
      backdropOpacity = v;
      notifyListeners();
    },
    curve: Curves.easeOut,
  )..disposeBy(this);

  void _hideBackdrop({bool animated = true}) {
    if (animated) {
      _backdropAnimator.animate(target: 0, duration: _backdropFade).unawaited();
    } else {
      _backdropAnimator.cancel();
      backdropOpacity = 0;
      notifyListeners();
    }
  }

  void _showBackdrop({bool animated = true}) {
    if (animated) {
      _backdropAnimator.animate(target: 1, duration: _backdropFade).unawaited();
    } else {
      _backdropAnimator.cancel();
      backdropOpacity = 1;
      notifyListeners();
    }
  }

  /// Tool-entry transition support (telegram keeps the backdrop
  /// hidden until `transitionInFinished`): the crop screen suspends
  /// it on push and restores it once the push transition lands.
  void suspendBackdropForTransition() => _hideBackdrop(animated: false);

  /// Shows the backdrop again, without animating, once the transition has
  /// landed.
  void restoreBackdropAfterTransition() => _showBackdrop(animated: false);

  /// Gesture-start hook: kill any in-flight settle spring and pending
  /// grid fade-out, show the thirds grid, drop the idle backdrop.
  /// [instantBackdrop] mirrors telegram's non-animated reset on
  /// handle drags vs the 0.16s fade on scroll gestures.
  void beginInteraction({bool instantBackdrop = false}) {
    _settleAnimator.cancel();
    _gridFadeTimer?.cancel();
    _gridFadeTimer = null;
    _gridAnimator.animate(target: 1, duration: _gridFade).unawaited();
    _hideBackdrop(animated: !instantBackdrop);
  }

  /// Gesture-end hook (all pointers up): spring back to coverage and
  /// schedule the grid fade-out + backdrop return.
  void endInteraction() {
    settleToCoverage().unawaited();
    _gridFadeTimer?.cancel();
    _gridFadeTimer = Timer(_confirmCountdown, () {
      if (disposed) return;
      _gridAnimator.animate(target: 0, duration: _gridFade).unawaited();
      _showBackdrop();
      if (cropChangedSinceConfirm) {
        cropChangedSinceConfirm = false;
        _constrainCropForConfirm();
        notifyListeners();
        confirmTick.value++;
      }
    });
  }

  @override
  void dispose() {
    _gridFadeTimer?.cancel();
    super.dispose();
  }

  /// Snapshot taken on tool-open. Tool-cancel calls [restoreSnapshot]
  /// to roll the layer back to this state. Apply is a no-op (the layer's
  /// current state IS the committed state). Mirrors telegram-iOS's
  /// `previousDrawingData = self.mediaEditor.values.drawing`
  /// (`MediaEditorScreen.swift:6086`).
  CropSnapshot? _snapshot;

  /// True if the layer has any applied edits beyond the default state
  /// (used by [ComposeEntry] to decide whether to rasterise on submit).
  bool get hasAppliedEdits =>
      imageTransform.rotateZ != 0 ||
      imageTransform.flipX != 1 ||
      crop != (Offset.zero & imageSize);

  /// Capture current state for later [restoreSnapshot].
  void saveSnapshot() {
    _revertSession = null;
    rotationScaleFloor = null;
    _snapshot = CropSnapshot._(
      imageTransform: imageTransform.clone(),
      crop: crop,
    );
  }

  /// In-session data state captured when [driveSnapshotRevert] first
  /// engages, so the blend has a stable endpoint while the swipe
  /// scrubs back and forth.
  UserTransform? _revertSession;

  /// Interactive counterpart of [restoreSnapshotAnimated]: blends the
  /// RENDER transform between the last [saveSnapshot] (t = 0) and the
  /// in-session state (t = 1). The crop screen maps its swipe-back
  /// progress here so the image visibly un-zooms with the finger.
  /// t back at 1 releases the drive (aborted swipe). Data state is
  /// untouched — a completed swipe pops the screen, whose restore
  /// path commits the snapshot and animates the remainder.
  ///
  /// flipX is excluded from the blend (interpolating it through zero
  /// squashes the image); a session flip reverses via the card-flip
  /// in the post-pop restore instead.
  void driveSnapshotRevert(double t) {
    final s = _snapshot;
    if (s == null) return;
    if (t >= 1) {
      if (_revertSession == null) return;
      _revertSession = null;
      final flipX = _renderTransform.flipX;
      _renderTransform.update(imageTransform);
      _renderTransform.flipX = flipX;
      _showBackdrop(animated: false);
      notifyListeners();
      return;
    }
    _settleAnimator.cancel();
    _renderAnimator.cancel();
    if (_revertSession == null) _hideBackdrop(animated: false);
    final session = _revertSession ??= imageTransform.clone();
    final flipX = _renderTransform.flipX;
    _renderTransform.update(
      s.imageTransform +
          (session - s.imageTransform) * t.clamp(0.0, 1.0).toDouble(),
    );
    _renderTransform.flipX = flipX;
    notifyListeners();
  }

  /// Restore the layer to the last [saveSnapshot]. No-op if none saved.
  void restoreSnapshot() {
    final s = _snapshot;
    if (s == null) return;
    _revertSession = null;
    rotationScaleFloor = null;
    _settleAnimator.cancel();
    _renderAnimator.cancel();
    _flipAnimator.cancel();
    _flipDecoration = 0;
    imageTransform.update(s.imageTransform);
    crop = s.crop;
    _showBackdrop(animated: false);
    notifyListeners();
  }

  /// Like [restoreSnapshot] but smoothly reverses the in-session
  /// transforms instead of snapping them. Data state snaps synchronously
  /// (callers — including the host — see the restored values immediately);
  /// the render-side animator interpolates the visual rotate / pan /
  /// scale back to the snapshot, and a session-flip plays its card-flip
  /// arc in reverse. `CropScreen._cancel` fires this unawaited and
  /// then pops, so the reverse overlaps with the screen's pop transition.
  ///
  /// The crop rect is snapped — animating an arbitrary `Rect` doesn't
  /// compose well with the rest of the reverse and crop-rect changes
  /// are rarely what users undo.
  Future<void> restoreSnapshotAnimated() async {
    final s = _snapshot;
    if (s == null) return;
    _revertSession = null;
    rotationScaleFloor = null;
    _settleAnimator.cancel();
    crop = s.crop;
    final flipChanged = s.imageTransform.flipX != imageTransform.flipX;
    final preRender = _renderTransform.clone();
    _suppressMirror = true;
    imageTransform.update(s.imageTransform);
    _suppressMirror = false;
    _renderTransform.update(preRender);
    _renderTransform.flipX = s.imageTransform.flipX;
    notifyListeners();
    if (flipChanged) {
      _flipDecoration = dartmath.pi;
      _flipAnimator.animate(target: 0);
    }
    await _renderAnimator.animate(target: s.imageTransform);
    final flipX = _renderTransform.flipX;
    _renderTransform.update(s.imageTransform);
    _renderTransform.flipX = flipX;
    notifyListeners();
  }

  /// Inverse of the full viewport-rendering transform —
  /// `viewport = camera · sandwich(imageTransform) · source`.
  /// Used by composed-scene gesture handlers (e.g. `DrawGestures`) that
  /// need to convert pointer-in-viewport coordinates back to
  /// source-space so strokes recorded in a crop-overlayed editor still
  /// land in the right place on the original source.
  Offset viewportToSource(Offset viewport, {required math.Matrix4 camera}) {
    final scale = camera.storage[0];
    final tx = camera.storage[12];
    final ty = camera.storage[13];
    if (scale.abs() < 1e-9) return viewport;
    final imagePoint = Offset(
      (viewport.dx - tx) / scale,
      (viewport.dy - ty) / scale,
    );

    final cx = imageSize.width / 2;
    final cy = imageSize.height / 2;
    final inv = math.Matrix4.copy(imageTransform.matrix)..invert();
    final v = math.Vector3(imagePoint.dx - cx, imagePoint.dy - cy, 0)
      ..applyMatrix4(inv);

    return Offset(v.x + cx, v.y + cy);
  }

  /// Returns the image to no pan, zoom, rotation or flip. The data state
  /// snaps; the visible transform eases to it, and the future completes when
  /// it has.
  Future<void> resetImage() {
    _settleAnimator.cancel();
    final target = UserTransform.zero();
    final flipChanged = target.flipX != imageTransform.flipX;
    final preRender = _renderTransform.clone();
    _suppressMirror = true;
    imageTransform.update(target);
    _suppressMirror = false;
    rotationScaleFloor = null;
    _renderTransform.update(preRender);
    _renderTransform.flipX = target.flipX;
    notifyListeners();
    if (flipChanged) {
      _flipDecoration = dartmath.pi;
      _flipAnimator.animate(target: 0);
    }
    return _spin(target);
  }

  /// Rotate the image 90° counter-clockwise (one quarter turn).
  /// [imageTransform] snaps so callers / tests / gestures see the new
  /// rotation immediately; the visible rotation eases over [kAnimation].
  ///
  /// The turn is around [crop].center, not the image centre: pan is
  /// remapped so the content in the crop stays put and rotates, the
  /// same pivot [flipHorizontal] uses for the mirror. A quarter turn
  /// can uncover a non-square crop; the data state then snaps to the
  /// nearest covering transform so the animation lands on a valid
  /// state.
  void rotate90() {
    _settleAnimator.cancel();
    captureRotationFloor();
    final preRender = _renderTransform.clone();
    _suppressMirror = true;
    imageTransform.update(
      _coveredAt(
        imageTransform.rotateZ - math.degrees2Radians * 90,
        scaleFloor: imageTransform.totalScale,
      ),
    );
    _suppressMirror = false;
    _renderAnimator.cancel();
    _renderTransform.update(preRender);
    _spin(imageTransform.clone()).unawaited();
  }

  /// Map [t.offset] through a [delta] rotation about [crop].center.
  /// Flip sits outside rotateZ, so the visual turn is `F R(delta) F⁻¹`.
  void _pivotOffsetAroundCrop(UserTransform t, double delta) {
    final px = crop.center.dx - imageSize.width / 2;
    final py = crop.center.dy - imageSize.height / 2;
    final vx = t.offset.x - px;
    final vy = t.offset.y - py;
    final c = dartmath.cos(delta);
    final s = dartmath.sin(delta);
    final flip = t.flipX;
    t.offset = math.Vector3(
      px + c * vx - flip * s * vy,
      py + flip * s * vx + c * vy,
      0,
    );
  }

  /// Spring the rotation back to 0, re-covering the crop at the zoom
  /// the dial holds ([rotationScaleFloor]) rather than at the widest
  /// coverage the rotation passed through. [imageTransform] snaps; the
  /// visible rotation springs there over [kTgSpring].
  void resetRotation() {
    if (imageTransform.totalRotate == 0) return;
    final preRender = _renderTransform.clone();
    _suppressMirror = true;
    rotateCovered(0, scaleFloor: rotationScaleFloor);
    _suppressMirror = false;
    _renderTransform.update(preRender);
    rotationScaleFloor = null;
    _spin(
      imageTransform.clone(),
      duration: kTgSpring,
      curve: const TgSpringCurve(),
    ).unawaited();
  }

  /// Flip the image horizontally. Data flipX snaps; the visible flip
  /// runs as a card flip — Y-axis tilt eased from π → 0 — over
  /// [kAnimation].
  ///
  /// The flip mirrors the CROPPED VIEW in place (telegram's model), not
  /// the image about its own centre: the pan offset is mirrored about
  /// the crop-centre axis so the content inside the crop stays put and
  /// mirrors, instead of sliding sideways when the crop is off-centre.
  void flipHorizontal() {
    _settleAnimator.cancel();
    imageTransform.flipX = imageTransform.flip ? 1 : -1;
    imageTransform.offset = math.Vector3(
      2 * (crop.center.dx - imageSize.width / 2) - imageTransform.offset.x,
      imageTransform.offset.y,
      0,
    );
    imageTransform.notifyListeners();
    _flipDecoration = dartmath.pi;
    _hideBackdrop(animated: false);
    _flipAnimator.animate(target: 0).then((_) {
      if (!disposed) _showBackdrop(animated: false);
    }).unawaited();
  }

  /// Resize the crop rectangle to the given aspect ratio (width / height),
  /// or pass `null` to free the crop and reset to the full image.
  ///
  /// The crop stays centered and is scaled to fit inside the current image
  /// bounds.
  void setAspectRatio(double? ratio) {
    if (ratio == null) {
      lockedAspectRatio = null;
      crop = Offset.zero & imageSize;
    } else {
      lockedAspectRatio = 1 / ratio;
      final imgRatio = imageSize.width / imageSize.height;
      final w = ratio >= imgRatio ? imageSize.width : imageSize.height * ratio;
      final h = ratio >= imgRatio ? imageSize.width / ratio : imageSize.height;
      crop = Rect.fromCenter(
        center: Offset(imageSize.width / 2, imageSize.height / 2),
        width: w,
        height: h,
      );
    }
    // Telegram's `setLockedAspectRatio performResize:` runs the zoom
    // and area springs in parallel — the settle covers the transform
    // half, the immediate confirm tick lets the screen refit the
    // camera alongside it.
    _hideBackdrop(animated: false);
    settleToCoverage().then((_) {
      if (!disposed) _showBackdrop(animated: false);
    }).unawaited();
    cropChangedSinceConfirm = false;
    confirmTick.value++;
    notifyListeners();
  }

  @override
  Size get exportSize => crop.size;

  /// The source-pixel → output-pixel affine [paintExportOf] bakes (with
  /// `flipDecoration == 0`): move the crop origin to the output origin,
  /// then apply the centered [imageTransform] (pan / scale / rotateZ /
  /// flipX). The output canvas is [exportSize]. A pure 2D affine — no
  /// perspective, since the card-flip decoration is only a live-edit
  /// animation. The video export path hands this same matrix to the
  /// native encoder (and the live cropped-video preview paints with it),
  /// so the exported frames match the on-screen crop exactly.
  math.Matrix4 get exportMatrix {
    final cx = imageSize.width / 2;
    final cy = imageSize.height / 2;
    return math.Matrix4.identity()
      ..translateByVector3(math.Vector3(cx - crop.left, cy - crop.top, 0))
      ..multiply(imageTransform.matrix)
      ..translateByVector3(math.Vector3(-cx, -cy, 0));
  }

  @override
  void paintExport(Canvas canvas, Size size) {
    paintExportOf(canvas, size, image);
  }

  /// Apply this layer's crop transform to a different [source] image
  /// (instead of `this.image`). Used by [ComposeEntry._composeLayers]
  /// to compose tools as a pipeline: the source is first painted with
  /// strokes from the draw layer (in source-space), then THAT result is
  /// fed here for the geometric clip / rotate / flip. Matches telegram's
  /// pipeline (source → paint → crop) — strokes survive re-cropping
  /// because they're in source-space.
  ///
  /// [source] must share dims with `this.image` so [imageTransform] and
  /// [crop] (both in image-space) map correctly.
  void paintExportOf(Canvas canvas, Size size, ui.Image source) {
    assert(
      source.width == image.width && source.height == image.height,
      'paintExportOf input must share dims with the layer source image',
    );
    canvas.save();
    canvas.translate(-crop.left, -crop.top);
    _paintCroppedImageWith(canvas, source, Paint(), imageTransform, 0);
    canvas.restore();
  }

  @override
  void paintViewport(Canvas canvas, Size size, {required math.Matrix4 camera}) {
    canvas.save();
    canvas.transform(camera.storage);

    _paintGuideImage(canvas, Paint()..color = const Color(0x73000000));
    if (backdropOpacity > 0) {
      _paintBackdrop(canvas, camera);
    }
    _paintCroppedImageWith(
      canvas,
      image,
      Paint(),
      _renderTransform,
      _flipDecoration,
    );
    _paintGridLines(canvas, crop, camera);

    canvas.restore();
  }

  void _paintGuideImage(Canvas canvas, Paint paint) {
    canvas.save();
    _applyImageMatrix(canvas, _renderTransform, _flipDecoration);
    canvas.drawImage(image, Offset.zero, paint);
    canvas.restore();
  }

  /// Idle-state treatment of the area outside the crop: a dark
  /// blurred rendition of the image, telegram's
  /// `UIBlurEffectStyleDark` backdrop over the guide. Painted UNDER
  /// the cropped region (which covers the interior), faded by
  /// [backdropOpacity]. Blur sigma is screen-constant.
  void _paintBackdrop(Canvas canvas, math.Matrix4 camera) {
    final cameraScale = camera.storage[0].abs();
    if (cameraScale < 1e-9) return;
    final sigma = 20.0 / cameraScale;
    canvas.save();
    _applyImageMatrix(canvas, _renderTransform, _flipDecoration);
    canvas.drawImage(
      image,
      Offset.zero,
      Paint()
        ..color = const Color(0xFFFFFFFF).withValues(alpha: backdropOpacity)
        ..colorFilter = const ColorFilter.mode(
          Color(0xB3000000),
          BlendMode.srcATop,
        )
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: sigma,
          sigmaY: sigma,
          tileMode: ui.TileMode.decal,
        ),
    );
    canvas.restore();
  }

  void _paintCroppedImageWith(
    Canvas canvas,
    ui.Image source,
    Paint paint,
    UserTransform transform,
    double flipDecoration,
  ) {
    // clipRect, not saveLayer bounds: Impeller (iOS) does not reliably
    // confine the layer to the bounds here, letting the image cover the
    // backdrop outside the crop.
    canvas.save();
    canvas.clipRect(crop);
    _applyImageMatrix(canvas, transform, flipDecoration);
    canvas.drawImage(source, Offset.zero, paint);
    canvas.restore();
  }

  void _applyImageMatrix(
    Canvas canvas,
    UserTransform transform,
    double flipDecoration,
  ) {
    canvas.translate(imageSize.width / 2, imageSize.height / 2);
    if (flipDecoration != 0) {
      // Composed outside the user transform: the tilt's Y axis stays
      // viewport-vertical, and at decoration=π it exactly cancels the
      // already-flipped flipX (regardless of the user's rotateZ).
      // Pivoted on the crop-centre axis — the same axis flipHorizontal
      // mirrors the pan about — so decoration=π reproduces the
      // pre-flip frame exactly and the card turns around the crop.
      final pivotX = crop.center.dx - imageSize.width / 2;
      final tilt = math.Matrix4.identity()
        ..setEntry(3, 2, -1.0 / imageSize.width)
        ..rotateY(flipDecoration);
      canvas.translate(pivotX, 0);
      canvas.transform(tilt.storage);
      canvas.translate(-pivotX, 0);
    }
    canvas.transform(transform.matrix.storage);
    canvas.translate(-imageSize.width / 2, -imageSize.height / 2);
  }

  void _paintGridLines(Canvas canvas, Rect rect, math.Matrix4 camera) {
    final scale = 1 / camera.storage[0];

    final med = Paint()
      ..color = colors.onMedia
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1 * scale;
    final thin = Paint()
      ..color = colors.onMedia.withValues(alpha: colors.onMedia.a * gridOpacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = .5 * scale;
    final thick = Paint()
      ..color = colors.onMedia
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2 * scale
      ..strokeCap = StrokeCap.butt;

    final corner = 16.0 * scale;
    final path = Path()
      ..moveTo(rect.left, rect.top + corner)
      ..lineTo(rect.left, rect.top)
      ..lineTo(rect.left + corner, rect.top)
      ..moveTo(rect.right - corner, rect.top)
      ..lineTo(rect.right, rect.top)
      ..lineTo(rect.right, rect.top + corner)
      ..moveTo(rect.right, rect.bottom - corner)
      ..lineTo(rect.right, rect.bottom)
      ..lineTo(rect.right - corner, rect.bottom)
      ..moveTo(rect.left + corner, rect.bottom)
      ..lineTo(rect.left, rect.bottom)
      ..lineTo(rect.left, rect.bottom - corner)
      ..moveTo(rect.left, rect.top + corner)
      ..close();

    canvas.drawPath(path, thick);

    final box = rect.deflate(1 * scale);
    if (gridOpacity > 0) {
      for (int step = 1; step < 3; step++) {
        final dv = Offset(0, box.height * step / 3);
        final dh = Offset(box.width * step / 3, 0);
        canvas.drawLine(box.topLeft + dv, box.topRight + dv, thin);
        canvas.drawLine(box.topLeft + dh, box.bottomLeft + dh, thin);
      }
    }
    canvas.drawRect(box, med);
  }
}

/// Image-space user transform: pan offset, scale, rotate, flip-X. Composes
/// into a [Matrix4] applied during paint and during export. Implements the
/// `+ - *` operators so [Animator] can tween between snapshots.
class UserTransform with Emitter {
  /// Pan, in image pixels.
  math.Vector3 offset = math.Vector3.zero();

  /// Committed zoom.
  double scale = 1;

  /// Committed rotation, in radians.
  double rotateZ = 0;

  /// Horizontal scale sign: -1 mirrors.
  double flipX = 1;

  // In-flight gesture deltas — not yet committed to [scale]/[rotateZ].
  /// Rotation of the gesture in flight, on top of [rotateZ].
  double activeRotateZ = 0;

  /// Zoom of the gesture in flight, on top of [scale].
  double activeScale = 1;

  /// Committed plus in-flight rotation.
  double get totalRotate => rotateZ + activeRotateZ;

  /// Committed times in-flight zoom.
  double get totalScale => scale * activeScale;

  /// Whether the image is mirrored.
  bool get flip => flipX < 0;

  /// No pan, zoom, rotation or flip.
  static UserTransform zero() => UserTransform();

  /// Maps a point through the rotation, then the zoom with its flip, then the pan.
  math.Matrix4 get matrix {
    return math.Matrix4.identity()
      ..translateByVector3(offset)
      ..scaleByDouble(flipX * totalScale, totalScale, 1, 1)
      ..rotateZ(totalRotate);
  }

  @override
  void notifyListeners() => super.notifyListeners();

  /// Takes every field from [other] and notifies.
  void update(UserTransform other) {
    offset = other.offset;
    scale = other.scale;
    rotateZ = other.rotateZ;
    flipX = other.flipX;
    activeRotateZ = other.activeRotateZ;
    activeScale = other.activeScale;
    notifyListeners();
  }

  /// A copy that shares nothing with this transform.
  UserTransform clone() {
    return UserTransform()
      ..offset = math.Vector3.copy(offset)
      ..scale = scale
      ..rotateZ = rotateZ
      ..flipX = flipX
      ..activeRotateZ = activeRotateZ
      ..activeScale = activeScale;
  }

  /// The field-wise sum.
  UserTransform operator +(UserTransform other) {
    return UserTransform()
      ..offset = offset + other.offset
      ..scale = scale + other.scale
      ..rotateZ = rotateZ + other.rotateZ
      ..flipX = flipX + other.flipX
      ..activeRotateZ = activeRotateZ + other.activeRotateZ
      ..activeScale = activeScale + other.activeScale;
  }

  /// The field-wise difference.
  UserTransform operator -(UserTransform other) {
    return UserTransform()
      ..offset = offset - other.offset
      ..scale = scale - other.scale
      ..rotateZ = rotateZ - other.rotateZ
      ..flipX = flipX - other.flipX
      ..activeRotateZ = activeRotateZ - other.activeRotateZ
      ..activeScale = activeScale - other.activeScale;
  }

  /// Every field times [scalar].
  UserTransform operator *(double scalar) {
    return UserTransform()
      ..offset = offset * scalar
      ..scale = scale * scalar
      ..rotateZ = rotateZ * scalar
      ..flipX = flipX * scalar
      ..activeRotateZ = activeRotateZ * scalar
      ..activeScale = activeScale * scalar;
  }

  @override
  bool operator ==(Object other) {
    return other is UserTransform &&
        offset == other.offset &&
        scale == other.scale &&
        rotateZ == other.rotateZ &&
        flipX == other.flipX &&
        activeRotateZ == other.activeRotateZ &&
        activeScale == other.activeScale;
  }

  @override
  int get hashCode =>
      Object.hash(offset, scale, rotateZ, flipX, activeRotateZ, activeScale);
}

/// By-value snapshot of a [CropImageLayer]'s mutable user-edit state.
/// Captured at tool-open by [CropImageLayer.saveSnapshot]; consumed on
/// cancel by [CropImageLayer.restoreSnapshot]. Camera is host-owned and
/// not part of the snapshot — only fields user gestures actually mutate
/// are rolled back.
class CropSnapshot {
  CropSnapshot._({required this.imageTransform, required this.crop});

  /// The image transform at capture.
  final UserTransform imageTransform;

  /// The crop rectangle at capture.
  final Rect crop;
}

/// Pinch-to-zoom + drag-to-pan inside the crop rectangle. Scale and
/// rotation anchor at the gesture's focal point: the image point under
/// the fingers at gesture-start stays under them for the rest of the
/// gesture (same anchoring as [DrawGestures]' viewer camera).
class CropGestures extends StatefulWidget {
  /// Pans and zooms [layer]'s image as [hostCamera] shows it.
  const CropGestures({
    super.key,
    required this.layer,
    required this.hostCamera,
  });

  /// The layer whose image transform the gestures write.
  final CropImageLayer layer;

  /// The image-to-screen transform the gestures are read through.
  final ValueListenable<math.Matrix4> hostCamera;

  @override
  State<CropGestures> createState() => _CropGesturesState();
}

class _CropGesturesState extends State<CropGestures> {
  UserTransform get transform => widget.layer.imageTransform;

  /// Image point under the focal at gesture-start, relative to the
  /// image center (the pivot of [UserTransform.matrix]). Each update
  /// solves the offset that keeps it under the (moving) focal, which
  /// yields pan and focal-anchored zoom/rotate in one equation.
  ///
  /// [ScaleGestureRecognizer] rebases its scale/rotation whenever the
  /// pointer count changes, firing end + start around the change —
  /// [_onScaleEnd] commits the in-flight deltas and [_onScaleStart]
  /// re-captures the anchor, so tracking stays continuous across
  /// finger transitions.
  math.Vector3 _anchor = math.Vector3.zero();

  /// Gesture focal → image-layer space through the host camera
  /// (uniform scale + translate), relative to the image center.
  math.Vector3 _focalFromCenter(Offset focal) {
    final camera = widget.hostCamera.value;
    final center = widget.layer.imageSize.center(Offset.zero);
    return math.Vector3(
      (focal.dx - camera.storage[12]) / camera.storage[0] - center.dx,
      (focal.dy - camera.storage[13]) / camera.storage[5] - center.dy,
      0,
    );
  }

  /// Live pointer count. [ScaleGestureRecognizer] rebases to its
  /// `accepted` state on every pointer-count change and fires no end
  /// callback when the last motionless finger lifts, so "all fingers
  /// up" must come from the raw pointer stream. Trackpad pinch arrives
  /// as pan-zoom start/end, not pointer down/up.
  int _pointers = 0;

  /// True while the current recognizer gesture began during a handle
  /// drag — its updates are dropped wholesale (telegram's
  /// `shouldBeginChanging` returning false).
  bool _suppressed = false;

  /// True once the current recognizer gesture actually pinched. A pinch
  /// — in or out — is the user choosing a zoom, so it becomes the
  /// rotation dial's floor; a pan or a two-finger rotate is not.
  bool _scaled = false;

  void _onPointerBegan() {
    if (transform.disposed) return;
    if (_pointers++ == 0 &&
        !widget.layer.areaTracking &&
        !widget.layer.dialTracking) {
      widget.layer.scrollTracking = true;
      widget.layer.beginInteraction();
    }
  }

  void _onPointerStopped() {
    if (transform.disposed) return;
    if (--_pointers == 0 && widget.layer.scrollTracking) {
      widget.layer.scrollTracking = false;
      widget.layer.endInteraction();
    }
  }

  void _onScaleStart(ScaleStartDetails e) {
    if (transform.disposed) return;

    _scaled = false;
    _suppressed = widget.layer.areaTracking || !widget.layer.scrollTracking;
    if (_suppressed) return;

    final inv = math.Matrix4.copy(transform.matrix)..invert();
    _anchor = inv.transform3(_focalFromCenter(e.localFocalPoint));
  }

  /// Telegram's pinch envelope: hard stop at 10× the crop fill scale,
  /// rubber-banded resistance below fill, floored at a quarter of it
  /// (`TGPhotoCropScrollView.m:537-548`). Works on the scaled-width
  /// axis like telegram so the resistance feel matches.
  double _limitedScale(double gestureScale) {
    final layer = widget.layer;
    final width = layer.imageSize.width;
    final minSize = layer.fillScale * width;
    final maxSize = layer.maxTotalScale * width;
    final size =
        dartmath.min(transform.scale * gestureScale, layer.maxTotalScale) *
        width;
    final constrained = size.clamp(minSize, maxSize);
    final banded =
        constrained + _rubberBand(size - constrained, maxSize - minSize);
    return dartmath.max(minSize * 0.25, banded) / width / transform.scale;
  }

  double _rubberBand(double offset, double dimension) {
    final result =
        0.55 * offset.abs() * dimension / (dimension + 0.55 * offset.abs());
    return offset < 0 ? -result : result;
  }

  void _onScaleUpdate(ScaleUpdateDetails e) {
    if (transform.disposed || _suppressed) return;

    if (e.scale != 1) _scaled = true;

    // When flipped horizontally the matrix mirrors the image, which
    // inverts the perceived rotation direction — a clockwise gesture
    // would visibly rotate counter-clockwise. Negate the gesture's
    // rotation when flipped so the visual rotation matches the user's
    // hand.
    transform.activeRotateZ = transform.flip ? -e.rotation : e.rotation;
    transform.activeScale = _limitedScale(e.scale);

    final scaleRotate = math.Matrix4.identity()
      ..scaleByDouble(
        transform.flipX * transform.totalScale,
        transform.totalScale,
        1,
        1,
      )
      ..rotateZ(transform.totalRotate);
    final moved = scaleRotate.transform3(math.Vector3.copy(_anchor));
    transform.offset = _focalFromCenter(e.localFocalPoint)..sub(moved);
    transform.notifyListeners();
  }

  void _onScaleEnd(ScaleEndDetails e) {
    if (transform.disposed) return;
    if (_suppressed) {
      _suppressed = false;
      return;
    }

    transform.scale *= transform.activeScale;
    transform.activeScale = 1;
    transform.rotateZ += transform.activeRotateZ;
    transform.activeRotateZ = 0;
    transform.notifyListeners();

    if (_scaled) {
      widget.layer.rotationScaleFloor = transform.totalScale;
    } else {
      widget.layer.captureRotationFloor();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _onPointerBegan(),
      onPointerUp: (_) => _onPointerStopped(),
      onPointerCancel: (_) => _onPointerStopped(),
      onPointerPanZoomStart: (_) => _onPointerBegan(),
      onPointerPanZoomEnd: (_) => _onPointerStopped(),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onScaleStart: _onScaleStart,
        onScaleUpdate: _onScaleUpdate,
        onScaleEnd: _onScaleEnd,
      ),
    );
  }
}
