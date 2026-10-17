import 'dart:math' as math;

import 'package:ux/src/media/compose/compose_constants.dart';
import 'package:ux/src/media/compose/tool_chrome.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:ux/src/media/editors/animator.dart';
import 'package:ux/src/media/editors/crop_image_layer.dart';
import 'package:ux/src/media/editors/crop_rotation_dial.dart';
import 'package:ux/src/media/editors/draw_image_layer.dart';
import 'package:ux/src/media/editors/editor.dart';
import 'package:ux/src/media/editors/entity_layer.dart';
import 'package:ux/ux.dart';
import 'package:vector_math/vector_math_64.dart' as vmath;

/// Pushed tool screen for the crop editor. Borrows a [CropImageLayer]
/// from the host (e.g. `ComposeEntry`); on push the layer snapshots its
/// state, on cancel it restores from the snapshot, on apply it commits
/// (current state IS committed). Pops with `true` on apply / `false` on
/// cancel. The host re-renders its preview from the committed layer
/// state: an image's preview is the composite `ComposeEntry.composedImage`
/// gives the submit, and a video's crop rides `ComposeResult.videoEdit`.
///
/// See [DrawScreen] for the rationale behind the instant
/// `ScreenTransitions.none` transition and shared-image model.
class CropScreen with Screen<bool>, Emitter {
  /// Creates the screen over the host's [layer] and [camera].
  CropScreen.borrowed({
    required this.layer,
    required this.camera,
    required this.setFitRect,
    this.refitCamera,
    this.draw,
    this.entities,
  });

  /// The crop layer being edited.
  final CropImageLayer layer;

  /// Optional draw layer from the host. When the entry has prior
  /// strokes, the crop editor renders them on top of the source so
  /// the user can see what they've drawn while adjusting the crop
  /// handles. Strokes paint at source-space coords through the same
  /// `imageTransform` as the image, so they rotate/flip together.
  final DrawImageLayer? draw;

  /// Optional entity layer from the host. Its overlays render on top of
  /// the source through the same `imageTransform` as the strokes, so the
  /// user sees them rotate / flip while adjusting the crop handles.
  final EntityLayer? entities;

  /// Host-owned viewport camera. Shared with the underlying compose
  /// page so the editor surface stays at the same on-screen rect when
  /// the tool pushes / pops.
  final ValueListenable<vmath.Matrix4> camera;

  /// Push the rect (in scaffold-body coords) where the image should
  /// fit. The host's `cameraAnimator` interpolates from compose's
  /// rect → this screen's rect on activation, so the image animates
  /// smoothly from compose's position to crop's. On pop, compose's
  /// `onActive` re-pushes its own rect and the animator runs the
  /// reverse transition.
  final ValueChanged<Rect> setFitRect;

  /// Re-target the host camera at the current crop rect — telegram's
  /// evenlyFill refit. Invoked on the layer's confirm tick (1s after
  /// a handle drag, immediately on an aspect snap) with the TgSpring.
  final void Function({Curve? curve, Duration? duration})? refitCamera;

  late final ValueNotifier<double> _chromeHeight = ValueNotifier<double>(0);

  Size? _lastBody;
  bool _active = true;
  bool _chromeMeasured = false;

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
    super.dispose();
  }

  void _publish() {
    final body = _lastBody;
    // Skip until chrome is measured at least once. Otherwise the very
    // first publish (post first LayoutBuilder, before OnSize fires)
    // pushes a too-tall rect with chromeHeight=0, the animator targets
    // it, then the next publish corrects — visible as a brief
    // shrink-then-enlarge detour.
    if (body == null || !_active || disposed || !_chromeMeasured) return;
    final topGutter = math.max(_safeAreaTop, kEditorSurfacePadding);
    final rect = Rect.fromLTRB(
      kEditorSurfacePadding,
      topGutter,
      body.width - kEditorSurfacePadding,
      body.height - _chromeHeight.value - kCropDialBandHeight,
    );
    setFitRect(rect);
  }

  // viewPaddingOf is read inside buildPresenter; this is the cached
  // value used by [_publish] when called from `onActive`.
  double _safeAreaTop = 0;

  /// The crop editor this screen shows.
  late final Editor editor = Editor.crop(
    layer: layer,
    draw: draw,
    entities: entities,
    camera: camera,
    onCancel: _cancel,
    onSubmit: _apply,
  );

  /// True once Apply or Cancel decided the screen's fate; gates the
  /// swipe-revert machinery off their explicit pop paths.
  bool _resolved = false;

  /// The stack's transition animation (1 = presented). During an
  /// interactive swipe-back the stack scrubs it with the finger, so
  /// its value doubles as swipe progress: it drives the layer's
  /// render blend back toward the snapshot, the image un-zooming
  /// with the drag. During push (0→1) session == snapshot and the
  /// blend is the identity.
  Animation<double>? _transition;

  /// Set once the push transition first reaches fully-presented; the
  /// idle backdrop appears at that moment (telegram's
  /// `transitionInFinished` → `showBackdropViewAnimated`).
  bool _entryLanded = false;

  void _onTransitionTick() {
    if (_resolved || popped || disposed) return;
    if (!_entryLanded && _transition!.value >= 1) {
      _entryLanded = true;
      layer.restoreBackdropAfterTransition();
      return;
    }
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
    layer.suspendBackdropForTransition();
    layer.confirmTick.subscribe(_onConfirm).disposeBy(this);
  }

  void _onConfirm() {
    if (_resolved || popped) return;
    refitCamera?.call(curve: const TgSpringCurve(), duration: kTgSpring);
  }

  @override
  void onDetach() {
    // A swipe-back (or any external pop) bypasses the Cancel button —
    // roll the borrowed layer back exactly like Cancel, continuing
    // from wherever the interactive revert left the render state.
    if (!_resolved) {
      _resolved = true;
      layer.restoreSnapshotAnimated().unawaited();
    }
    super.onDetach();
  }

  Future<void> _apply() async {
    _resolved = true;
    pop(true);
  }

  Future<void> _cancel() async {
    _resolved = true;
    // Fire the reverse imageTransform animation unawaited so it
    // overlaps with the pop transition (CropScreen stays rendered
    // for ~200ms while it animates out, the camera also runs back
    // to compose-fit over the same window).
    layer.restoreSnapshotAnimated().unawaited();
    pop(false);
  }

  @override
  Widget buildPresenter(BuildContext context) {
    _safeAreaTop = MediaQuery.viewPaddingOf(context).top;
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
            bottom: 0,
            child: OnSize(
              onSize: (s) {
                _chromeMeasured = true;
                _chromeHeight.value = s.height;
              },
              child: SafeArea(
                top: false,
                child: AnimatedToolChrome(child: editor.controls!),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
