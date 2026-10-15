import 'dart:math' as math;

import 'package:ux/src/media/compose/compose_constants.dart';
import 'package:ux/src/media/compose/tool_chrome.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:ux/src/media/editors/animator.dart';
import 'package:ux/src/media/editors/camera_fit.dart';
import 'package:ux/src/media/editors/crop_image_layer.dart';
import 'package:ux/src/media/editors/draw_image_layer.dart';
import 'package:ux/src/media/editors/editor.dart';
import 'package:ux/src/media/editors/editor_insets.dart';
import 'package:ux/src/media/editors/entity_layer.dart';
import 'package:ux/src/media/editors/text_entity.dart';
import 'package:ux/ux.dart';
import 'package:vector_math/vector_math_64.dart' as vmath;

/// Pushed tool screen for the draw editor. Borrows a [DrawImageLayer]
/// and an optional [EntityLayer] from the host (e.g. `ComposeEntry`);
/// on push they snapshot their state, on cancel they restore, on apply
/// they commit. Pops `true` on apply / `false` on cancel.
///
/// The transition is intentionally instant (`ScreenTransitions.none`):
/// both the host compose page and this screen render the same source
/// image at the same physical rect, so the canvas stays visually
/// static across the boundary while only the chrome swaps. Mirrors
/// telegram's `animateOutToTool` / `animateInFromTool` model.
class DrawScreen with Screen<bool>, Emitter {
  /// Creates the screen over the host's [layer] and [camera].
  DrawScreen.borrowed({
    required this.layer,
    required this.camera,
    required this.setFitRect,
    this.crop,
    this.entities,
  });

  /// The draw layer being edited.
  final DrawImageLayer layer;

  /// Optional crop layer from the host. When the entry has applied
  /// crop edits, the draw editor's canvas is the cropped preview
  /// (source × strokes → crop transform → clipped to crop rect) and
  /// new pointer events are converted from viewport-pixels to
  /// source-space through the crop's inverse transform — so strokes
  /// land at the right source pixel even though the user is drawing
  /// on the cropped view.
  final CropImageLayer? crop;

  /// Optional entity layer from the host. Its overlays paint above the
  /// strokes in source-space, so they clip and transform with the image
  /// exactly as the export pipeline renders them.
  final EntityLayer? entities;

  /// Host-owned viewport camera. Shared with the underlying compose
  /// page so the editor surface stays at the same on-screen rect when
  /// the tool pushes / pops.
  final ValueListenable<vmath.Matrix4> camera;

  /// Push the rect (in scaffold-body coords) where the image should
  /// fit. The host's `cameraAnimator` interpolates from compose's
  /// rect → this screen's rect on activation.
  final ValueChanged<Rect> setFitRect;

  /// Screen-local pan + zoom transform driven by two-finger gestures.
  /// Resets to identity each DrawScreen push — the zoom is a viewport
  /// adjustment for stroke precision, not a committed adjustment, so
  /// it doesn't survive back on the host or into the crop editor.
  late final ValueNotifier<vmath.Matrix4> viewerCamera =
      ValueNotifier<vmath.Matrix4>(vmath.Matrix4.identity());

  /// Animates [viewerCamera] back to identity on close (cancel or
  /// apply) so a user who pinch-zoomed for precision sees the zoom
  /// slide away during the 200 ms screen-pop transition instead of
  /// snapping. Short-circuits when the camera is already identity.
  late final _viewerAnimator = Animator<CameraFit>(
    getter: () => CameraFit.fromMatrix(viewerCamera.value),
    setter: (f) => viewerCamera.value = f.toMatrix(),
    curve: Curves.easeInOut,
  )..disposeBy(this);

  late final ValueNotifier<double> _chromeHeight = ValueNotifier<double>(0);

  /// Measured height of the bottom control strip. The editor's overlays
  /// subtract it from the band they lay out in.
  ValueListenable<double> get chromeHeight => _chromeHeight;

  Size? _lastBody;
  bool _active = true;
  bool _chromeMeasured = false;

  late final Listenable _insets = editorInsets;

  @override
  void onActive() {
    super.onActive();
    _active = true;
    _publish();
  }

  @override
  void onInactive() {
    super.onInactive();
    _active = false;
  }

  @override
  void dispose() {
    _transition?.removeListener(_onTransitionTick);
    _transition = null;
    _chromeHeight.dispose();
    Dispose.object(editor);
    viewerCamera.dispose();
    super.dispose();
  }

  Rect _fitRect(Size body) => Rect.fromLTRB(
    kEditorSurfacePadding,
    math.max(editorSafeAreaTop, kEditorSurfacePadding),
    body.width - kEditorSurfacePadding,
    body.height - _chromeHeight.value,
  );

  void _publish() {
    final body = _lastBody;
    // Skip until chrome is measured so we don't push a too-tall rect
    // (chromeHeight=0) that the animator targets and then has to undo.
    if (body == null || !_active || disposed || !_chromeMeasured) return;
    setFitRect(_fitRect(body));
  }

  /// Insert a text entity at the centre of the visible canvas — the fit rect
  /// less the chrome lift — and open the keyboard editor on it. Pose
  /// cancels the viewer zoom and the crop transform so the string sits
  /// upright in the current viewport.
  void insertTextEntity() {
    final layer = entities;
    final body = _lastBody;
    if (layer == null || body == null) return;
    final rect = _fitRect(body);
    final cropLayer = crop;
    final pose = textEntityViewPose(
      viewerCamera: viewerCamera.value,
      crop: cropLayer,
    );
    final wrap = cropLayer != null && cropLayer.hasAppliedEdits
        ? cropLayer.crop.width
        : layer.imageSize.width;
    layer.insertAndEdit(
      TextEntity(
        text: '',
        style: layer.pendingStyle,
        align: layer.pendingAlign,
        colour: layer.pendingColour,
        fontSize: layer.pendingFontSize,
        position: toSourcePoint(
          Offset(
            rect.center.dx,
            (rect.top + rect.bottom - editorKeyboardLift) / 2,
          ),
          hostCamera: camera.value,
          viewerCamera: viewerCamera.value,
          crop: crop,
        ),
        width: (wrap * 0.9).floorToDouble(),
        rotation: pose.rotation,
        scale: pose.scale,
      ),
    );
  }

  /// The draw editor this screen shows.
  late final Editor editor = Editor.draw(
    layer: layer,
    crop: crop,
    entities: entities,
    camera: camera,
    viewerCamera: viewerCamera,
    chromeHeight: _chromeHeight,
    insertText: insertTextEntity,
    onCancel: _cancel,
    onSubmit: _apply,
  );

  /// True once Apply or Cancel decided the screen's fate; gates the
  /// swipe-revert machinery off their explicit pop paths.
  bool _resolved = false;

  /// The stack's transition animation (1 = presented). An interactive
  /// swipe-back scrubs it with the finger; its value drives the
  /// session strokes' opacity so they fade out with the drag.
  Animation<double>? _transition;

  void _onTransitionTick() {
    if (_resolved || popped || disposed) return;
    layer.driveSnapshotRevert(_transition!.value);
  }

  @override
  Widget buildTransition(
    BuildContext context,
    Animation<double> animation,
    Widget child,
  ) {
    if (!identical(_transition, animation)) {
      _transition?.removeListener(_onTransitionTick);
      _transition = animation..addListener(_onTransitionTick);
    }
    return ToolTransition(animation: animation, child: child);
  }

  @override
  Duration get transitionDuration => const Duration(milliseconds: 200);

  @override
  void onPush() {
    super.onPush();
    layer.saveSnapshot();
    entities?.saveSnapshot();
  }

  @override
  void onDetach() {
    // A swipe-back (or any external pop) bypasses the Cancel button —
    // discard the session strokes exactly like Cancel, continuing the
    // fade from wherever the interactive revert left it.
    if (!_resolved) {
      _resolved = true;
      layer.restoreSnapshotAnimated().unawaited();
      _viewerAnimator.animate(target: CameraFit.identity).unawaited();
    }
    super.onDetach();
  }

  Future<void> _apply() async {
    entities?.deselect();
    _resolved = true;
    _viewerAnimator.animate(target: CameraFit.identity).unawaited();
    pop(true);
  }

  Future<void> _cancel() async {
    _resolved = true;
    // Fire the session-stroke fade-out unawaited so it overlaps with
    // the pop transition + the host camera's reverse animation.
    layer.restoreSnapshotAnimated().unawaited();
    entities?.restoreSnapshot();
    _viewerAnimator.animate(target: CameraFit.identity).unawaited();
    pop(false);
  }

  @override
  Widget buildPresenter(BuildContext context) {
    return ListenableBuilder(
      listenable: _insets,
      builder: (context, _) => _buildScaffold(),
    );
  }

  Widget _buildScaffold() {
    return Scaffold(
      backgroundColor: const Color(0xFF000000),
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          Positioned.fill(
            child: ListenableBuilder(
              listenable: _chromeHeight,
              builder: (ctx, _) => LayoutBuilder(
                builder: (ctx2, constraints) {
                  _lastBody = constraints.biggest;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _publish();
                  });
                  return editor.buildPresenter(ctx2);
                },
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: editorKeyboardLift,
            child: OnSize(
              onSize: (s) {
                _chromeMeasured = true;
                _chromeHeight.value = s.height;
              },
              child: SafeArea(
                top: false,
                bottom: false,
                minimum: EdgeInsets.only(bottom: editorSafeAreaBottom),
                child: AnimatedToolChrome(child: editor.controls!),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
