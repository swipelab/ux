import 'dart:ui' as ui;

import 'package:ux/src/media/design.dart';
import 'package:ux/src/media/editors/crop_area_overlay.dart';
import 'package:ux/src/media/editors/crop_controls.dart';
import 'package:ux/src/media/editors/crop_image_layer.dart';
import 'package:ux/src/media/editors/crop_rotation_dial.dart';
import 'package:ux/src/media/editors/draw_controls.dart';
import 'package:ux/src/media/editors/draw_image_layer.dart';
import 'package:ux/src/media/editors/editor_insets.dart';
import 'package:ux/src/media/editors/entity_layer.dart';
import 'package:ux/src/media/editors/text_controls.dart';
import 'package:ux/src/media/editors/text_edit_overlay.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:ux/ux.dart';
import 'package:vector_math/vector_math_64.dart' as vmath;

/// A staged image editor — a stack of [Painter] / [Exporter] layers plus
/// optional gesture and overlay widgets, with a [controls] strip the host
/// renders in place of its own command bar while editing.
///
/// The viewport-fitting matrix (camera) is owned by the host
/// (`ComposeEntry`) and threaded through painter / layer / gestures via
/// [Editor.crop] / [Editor.draw]. Layers don't store or compute their
/// own — same matrix is shared across compose / crop / draw screens.
class Editor with Emitter {
  /// An editor with the given chrome; layers join through [add].
  Editor({
    this.controls,
    this.gestures,
    this.overlays,
    this.camera,
    CustomPainter? painter,
  }) : _customPainter = painter;

  /// Host-owned viewport matrix. Required for image editors; may be
  /// null for layer-stack editors that don't paint into a viewport.
  final ValueListenable<vmath.Matrix4>? camera;

  /// Optional override for the viewport painter. When supplied, replaces
  /// the default [EditorPainter] (which paints all `Painter` layers
  /// additively). Used by tool factories that need pipeline composition
  /// (e.g. draw-over-crop renders source × strokes → crop transform
  /// instead of two independent additive paints).
  final CustomPainter? _customPainter;

  /// Wraps a [CropImageLayer] with the crop / rotate / flip / aspect-ratio
  /// controls. The returned editor's exporter rasterises the cropped +
  /// transformed image at [CropImageLayer.exportSize].
  ///
  /// Aspect-ratio cycling is internal: each tap on the aspect-ratio
  /// button advances through `[free, 1:1, 4:5, 16:9]` and snaps the crop
  /// rectangle.
  ///
  /// Pass [layer] to reuse a pre-existing instance (the "borrowed"
  /// mode used by `CropScreen.borrowed`): the editor will NOT dispose
  /// the layer on dispose, so its state survives across tool re-entries.
  /// Pass [image] instead to construct + own a fresh layer.
  factory Editor.crop({
    ui.Image? image,
    CropImageLayer? layer,
    DrawImageLayer? draw,
    EntityLayer? entities,
    required ValueListenable<vmath.Matrix4> camera,
    required AsyncCallback onSubmit,
    required AsyncCallback onCancel,
  }) {
    assert(
      (image == null) != (layer == null),
      'Editor.crop: pass exactly one of image: or layer:',
    );
    final cropLayer = layer ?? CropImageLayer(image: image!);
    final ownsLayer = layer == null;

    final aspectRatios = <double?>[null, 1.0, 4 / 5, 16 / 9];
    final aspectIdx = ValueNotifier<int>(0);

    Future<void> handleCancel() async {
      await onCancel();
    }

    Future<void> handleSubmit() async {
      await onSubmit();
    }

    final controls = ListenableBuilder(
      listenable: cropLayer,
      builder: (context, _) => ValueListenableBuilder<int>(
        valueListenable: aspectIdx,
        builder: (context, _, _) => CropControls(
          onCancel: handleCancel,
          onRotate: cropLayer.rotate90,
          onFlip: cropLayer.flipHorizontal,
          isFlipped: cropLayer.imageTransform.flip,
          onAspectRatio: () {
            aspectIdx.value = (aspectIdx.value + 1) % aspectRatios.length;
            cropLayer.setAspectRatio(aspectRatios[aspectIdx.value]);
          },
          onSubmit: handleSubmit,
        ),
      ),
    );

    final editor = Editor(
      gestures: CropGestures(layer: cropLayer, hostCamera: camera),
      controls: controls,
      camera: camera,
      overlays: [
        CropRotationDial(layer: cropLayer, hostCamera: camera),
        CropAreaOverlay(layer: cropLayer, hostCamera: camera),
      ],
      painter: CropScenePainter(
        crop: cropLayer,
        camera: camera,
        draw: draw,
        entities: entities,
      ),
    )..add(cropLayer, owned: ownsLayer);
    if (draw != null) editor.add(draw, owned: false);
    if (entities != null) editor.add(entities, owned: false);
    return editor;
  }

  /// Wraps a [DrawImageLayer] with the color palette + cancel / undo /
  /// submit controls. The exporter composites the source image with all
  /// completed strokes.
  ///
  /// Pass [layer] for borrowed mode (host-owned layer survives across
  /// tool re-entries) or [image] to construct + own a fresh one.
  factory Editor.draw({
    ui.Image? image,
    DrawImageLayer? layer,
    CropImageLayer? crop,
    EntityLayer? entities,
    required ValueListenable<vmath.Matrix4> camera,
    ValueNotifier<vmath.Matrix4>? viewerCamera,
    required ValueListenable<double> chromeHeight,
    required VoidCallback insertText,
    required AsyncCallback onSubmit,
    required AsyncCallback onCancel,
  }) {
    assert(
      (image == null) != (layer == null),
      'Editor.draw: pass exactly one of image: or layer:',
    );
    final drawLayer = layer ?? DrawImageLayer(image: image!);
    final ownsLayer = layer == null;

    final mode = ValueNotifier<EditorMode>(EditorMode.draw);
    final controls = ListenableBuilder(
      listenable: Listenable.merge([mode, drawLayer, ?entities]),
      builder: (context, _) => switch (mode.value) {
        EditorMode.draw => DrawControls(
          layer: drawLayer,
          onCancel: () async => onCancel(),
          onSubmit: () async => onSubmit(),
          onText: () {
            mode.value = EditorMode.text;
            insertText();
          },
        ),
        EditorMode.text => TextControls(
          style: entities?.activeStyle ?? EntityLayer.defaultStyle,
          align: entities?.activeAlign ?? EntityLayer.defaultAlign,
          colour: entities?.activeColour ?? EntityLayer.defaultColour,
          onStyle: () => entities?.cycleStyle(),
          onAlign: () => entities?.toggleAlignment(),
          onColour: (colour) => entities?.setColour(colour),
          onDraw: () {
            entities
              ?..endEdit()
              ..deselect();
            mode.value = EditorMode.draw;
          },
          onText: () {
            entities?.endEdit();
            insertText();
          },
          onCancel: () async {
            if (entities?.editing == null) return onCancel();
            entities!.cancelEdit();
          },
          onSubmit: () async {
            if (entities?.editing == null) return onSubmit();
            entities!.endEdit();
          },
        ),
      },
    );
    final slider = ListenableBuilder(
      listenable: Listenable.merge([
        mode,
        drawLayer,
        ?entities,
        chromeHeight,
        editorInsets,
      ]),
      builder: (context, _) {
        if (mode.value == EditorMode.draw) {
          return BrushSizeSlider(
            value: drawLayer.normalizedThickness,
            colour: drawLayer.currentBrush == BrushType.eraser
                ? colors.onMedia
                : drawLayer.currentColor,
            onChanged: (v) => drawLayer.normalizedThickness = v,
          );
        }
        return Padding(
          // Clears the strip the keyboard lifts over the slider's resting
          // place.
          padding: EdgeInsets.only(
            bottom: entities?.editing == null
                ? 0.0
                : chromeHeight.value + editorKeyboardLift,
          ),
          child: BrushSizeSlider(
            value: entities?.activeFontSize ?? EntityLayer.defaultFontSize,
            colour: entities?.activeColour ?? EntityLayer.defaultColour,
            onChanged: (v) => entities?.setFontSize(v),
          ),
        );
      },
    );
    final editor = Editor(
      gestures: Stack(
        fit: StackFit.expand,
        children: [
          DrawGestures(
            layer: drawLayer,
            crop: crop,
            hostCamera: camera,
            viewerCamera: viewerCamera,
          ),
          if (entities != null)
            EntityGestures(
              layer: entities,
              crop: crop,
              hostCamera: camera,
              viewerCamera: viewerCamera,
              onSelect: () => mode.value = EditorMode.text,
              onDeselect: () => mode.value = EditorMode.draw,
            ),
        ],
      ),
      controls: controls,
      overlays: [
        TextEditOverlay(
          entities: entities,
          chromeHeight: chromeHeight,
          camera: camera,
          viewerCamera: viewerCamera,
          crop: crop,
          onDone: () => entities?.endEdit(),
        ),
        slider,
        if (entities != null)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: EntitySelectionPainter(
                  layer: entities,
                  camera: camera,
                  crop: crop,
                  viewerCamera: viewerCamera,
                ),
              ),
            ),
          ),
      ],
      camera: camera,
      painter: DrawScenePainter(
        draw: drawLayer,
        camera: camera,
        crop: crop,
        entities: entities,
        viewerCamera: viewerCamera,
      ),
    )..add(drawLayer, owned: ownsLayer);
    editor.addDispose(mode.dispose);
    if (crop != null) editor.add(crop, owned: false);
    if (entities != null) editor.add(entities, owned: false);
    return editor;
  }

  /// Command strip that the host (e.g. `ComposePage`) shows in place
  /// of the default media commands while editing.
  final Widget? controls;

  /// Optional gesture surface stacked on top of the painted layers.
  final Widget? gestures;

  /// Optional overlay widgets — chrome like a brush-size slider that doesn't
  /// belong on the gesture surface but should sit above the layers.
  final List<Widget>? overlays;

  /// Layered scene composing the visible viewport. Layers that mix in
  /// [Painter] paint into the viewport; layers that mix in [Exporter]
  /// also rasterise into the final exported image.
  final List<Emitter> layers = <Emitter>[];

  /// Layers the editor owns (will dispose on [dispose]). Borrowed
  /// layers (passed in by the host, e.g. `ComposeEntry`) are tracked
  /// in [layers] but excluded from disposal so their state survives
  /// across tool re-entries.
  final Set<Emitter> _ownedLayers = <Emitter>{};

  /// Add [layer] to the editor. The editor subscribes to its emissions
  /// so any layer change repaints / re-emits. Set [owned] to `false`
  /// when the host retains the layer across tool sessions.
  void add(Emitter layer, {bool owned = true}) {
    layer.subscribe(notifyListeners).disposeBy(this);
    layers.add(layer);
    if (owned) _ownedLayers.add(layer);
    notifyListeners();
  }

  @override
  void dispose() {
    for (final layer in _ownedLayers) {
      Dispose.object(layer);
    }
    super.dispose();
  }

  /// Render the editor's viewport — paints all [Painter] layers plus the
  /// optional [gestures] / [overlays] on top.
  Widget buildPresenter(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ListenableBuilder(
          listenable: this,
          builder: (context, _) => CustomPaint(
            painter: _customPainter ??
                EditorPainter(scene: this, camera: camera),
          ),
        ),
        ?gestures,
        ...?overlays,
      ],
    );
  }

  /// Rasterise the editor's [Exporter] layers into a [ui.Image]. The
  /// exported size is the bounding union of every exporter's
  /// [Exporter.exportSize].
  Future<ui.Image> export() async {
    final exporters = layers.whereType<Exporter>().toList();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final size = exporters.fold<Size>(
      Size.zero,
      (acc, e) => Size(
        acc.width > e.exportSize.width ? acc.width : e.exportSize.width,
        acc.height > e.exportSize.height ? acc.height : e.exportSize.height,
      ),
    );

    for (final exp in exporters) {
      exp.paintExport(canvas, size);
    }

    final picture = recorder.endRecording();
    return picture.toImage(size.width.toInt(), size.height.toInt());
  }
}

/// CustomPainter that delegates to all [Painter] layers in [scene] with
/// the host [camera] threaded through. Repaint is driven by the editor
/// itself (via `super.repaint: scene`) plus the camera if supplied.
class EditorPainter extends CustomPainter {
  /// Paints [scene]'s layers through [camera].
  EditorPainter({required this.scene, this.camera})
      : super(
          repaint:
              camera == null ? scene : Listenable.merge([scene, camera]),
        );

  /// The editor whose [Painter] layers are painted.
  final Editor scene;
  /// The host's image-to-viewport transform; the identity when absent.
  final ValueListenable<vmath.Matrix4>? camera;

  @override
  void paint(Canvas canvas, Size size) {
    final m = camera?.value ?? vmath.Matrix4.identity();
    for (final layer in scene.layers.whereType<Painter>()) {
      layer.paintViewport(canvas, size, camera: m);
    }
  }

  @override
  bool shouldRepaint(covariant EditorPainter oldDelegate) =>
      scene != oldDelegate.scene || camera != oldDelegate.camera;
}

/// Compose-aware viewport painter for the **draw** editor.
///
/// - When [crop] is `null` or has no applied edits, paints source ×
///   strokes × entities fitted via the host [camera].
/// - When [crop] has applied edits, renders the composed pipeline:
///   source × strokes × entities (in source-space) → through crop's
///   imageTransform → clipped to crop rect → fitted via the host camera.
///   The user sees what they'd see in the final export: the cropped
///   view as the drawing canvas. New strokes land in source-space via
///   `DrawGestures`' crop-aware coord conversion.
///
/// [viewerCamera], when supplied, is a screen-space transform stacked
/// ON TOP of the base composition — the user's two-finger pan + zoom
/// in the draw editor. The gesture system writes into this notifier
/// and we apply it before the host camera so panning / pinching
/// affects what's visible without mutating the underlying layers.
///
/// Crop frame guide (corner brackets, rule-of-thirds) is intentionally
/// NOT painted — this is the DRAW editor, not the crop editor.
class DrawScenePainter extends CustomPainter {
  /// Paints [draw] over its source, through [crop] when it has edits.
  DrawScenePainter({
    required this.draw,
    required this.camera,
    this.crop,
    this.entities,
    this.viewerCamera,
  }) : super(
          repaint: Listenable.merge([
            draw,
            camera,
            ?crop,
            ?entities,
            ?viewerCamera,
          ]),
        );

  /// The source image and its strokes.
  final DrawImageLayer draw;
  /// The host's image-to-viewport transform.
  final ValueListenable<vmath.Matrix4> camera;
  /// The crop the scene is shown through.
  final CropImageLayer? crop;
  /// The overlays painted with the strokes.
  final EntityLayer? entities;
  /// The pinch and pan applied on top of [camera].
  final ValueListenable<vmath.Matrix4>? viewerCamera;

  @override
  void paint(Canvas canvas, Size size) {
    final v = viewerCamera;
    if (v != null) {
      canvas.save();
      canvas.transform(v.value.storage);
    }

    final c = crop;
    final e = entities;
    final m = camera.value;
    if (c == null || !c.hasAppliedEdits) {
      canvas.save();
      canvas.transform(m.storage);
      draw.paintSourceAndStrokes(canvas);
      e?.paintEntitiesOnly(canvas, draw.imageSize);
      canvas.restore();
    } else {
      canvas.save();
      canvas.transform(m.storage);
      canvas.saveLayer(c.crop, Paint());
      canvas.translate(c.imageSize.width / 2, c.imageSize.height / 2);
      canvas.transform(c.imageTransform.matrix.storage);
      canvas.translate(-c.imageSize.width / 2, -c.imageSize.height / 2);
      draw.paintSourceAndStrokes(canvas);
      e?.paintEntitiesOnly(canvas, c.imageSize);
      canvas.restore();
      canvas.restore();
    }

    if (v != null) canvas.restore();
  }

  @override
  bool shouldRepaint(covariant DrawScenePainter oldDelegate) =>
      draw != oldDelegate.draw ||
      camera != oldDelegate.camera ||
      crop != oldDelegate.crop ||
      entities != oldDelegate.entities ||
      viewerCamera != oldDelegate.viewerCamera;
}

/// Compose-aware viewport painter for the **crop** editor.
///
/// - Paints [crop].paintViewport first (source dimmed outside crop +
///   source full inside crop + crop frame guide).
/// - Then overlays [draw]'s strokes and [entities]' overlays through the
///   same camera + imageTransform, so they rotate / flip with the image.
///   Neither is dimmed outside the crop rect — both sit ABOVE the dim
///   mask, like an annotation layer, so the user sees prior work while
///   adjusting the crop handles.
class CropScenePainter extends CustomPainter {
  /// Paints [crop]'s scene with [draw] and [entities] above its dim mask.
  CropScenePainter({
    required this.crop,
    required this.camera,
    this.draw,
    this.entities,
  }) : super(repaint: Listenable.merge([crop, camera, ?draw, ?entities]));

  /// The crop scene painted first.
  final CropImageLayer crop;
  /// The host's image-to-viewport transform.
  final ValueListenable<vmath.Matrix4> camera;
  /// The strokes overlaid through the crop's image transform.
  final DrawImageLayer? draw;
  /// The overlays painted through the crop's image transform.
  final EntityLayer? entities;

  @override
  void paint(Canvas canvas, Size size) {
    final m = camera.value;
    crop.paintViewport(canvas, size, camera: m);

    _paintDial(canvas, size, m);

    final d = draw;
    final e = entities;
    final strokes = d != null && d.hasAppliedEdits ? d : null;
    final overlays = e != null && e.hasAppliedEdits ? e : null;
    if (strokes == null && overlays == null) return;

    canvas.save();
    canvas.transform(m.storage);
    canvas.translate(crop.imageSize.width / 2, crop.imageSize.height / 2);
    canvas.transform(crop.imageTransform.matrix.storage);
    canvas.translate(-crop.imageSize.width / 2, -crop.imageSize.height / 2);
    strokes?.paintStrokesOnly(canvas, crop.imageSize);
    overlays?.paintEntitiesOnly(canvas, crop.imageSize);
    canvas.restore();
  }

  /// The dial spans the camera-mapped viewport, so it needs a camera
  /// with a scale — the host's starts at `Matrix4.zero` and gains one
  /// on the first fit.
  void _paintDial(Canvas canvas, Size size, vmath.Matrix4 m) {
    final s = m.storage[0];
    if (s <= 0) return;

    canvas.save();
    canvas.transform(m.storage);
    paintCropRotationDial(
      canvas,
      crop: crop.crop,
      rotate: crop.renderRotate,
      viewport: Rect.fromLTWH(
        -m.storage[12] / s,
        -m.storage[13] / s,
        size.width / s,
        size.height / s,
      ),
      scale: 1 / s,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CropScenePainter oldDelegate) =>
      crop != oldDelegate.crop ||
      camera != oldDelegate.camera ||
      draw != oldDelegate.draw ||
      entities != oldDelegate.entities;
}

/// Layer mixin: paint into the editor's viewport every frame. The host
/// passes its current [camera] (image-top-left → viewport).
mixin Painter {
  /// Paints the layer into a viewport of [size] through [camera].
  void paintViewport(Canvas canvas, Size size, {required vmath.Matrix4 camera});
}

/// Layer mixin: rasterise into the editor's exported image. The host calls
/// [paintExport] when the user submits the edit.
mixin Exporter {
  /// Paint into the export canvas. [size] is the editor-wide export size
  /// (max over all exporters), so layers must position themselves
  /// accordingly.
  void paintExport(Canvas canvas, Size size);

  /// This layer's intrinsic export size — typically the source image's
  /// natural dimensions.
  Size get exportSize;
}
