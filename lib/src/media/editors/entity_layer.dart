import 'dart:math' as math;

import 'package:ux/src/media/design.dart';
import 'package:ux/src/media/editors/crop_image_layer.dart';
import 'package:ux/src/media/editors/draw_image_layer.dart';
import 'package:ux/src/media/editors/editor.dart';
import 'package:ux/src/media/editors/text_entity.dart';
import 'package:ux/src/media/editors/text_entity_painter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:ux/src/media/touch.dart';
import 'package:ux/ux.dart';
import 'package:vector_math/vector_math_64.dart' as vmath;

/// Side-handle hit target, in screen points.
const double entitySelectionViewHandleSize = 44;

/// How far past the entity's bounds the selection frame is hittable, in
/// screen points.
const double entitySelectionFrameOutset = 22;

/// Width of the selection frame's and handles' strokes, in screen points.
const double entitySelectionStrokeWidth = 2;

/// Colour of the selection frame and its handles.
const Color entitySelectionColour = Color(0xFFFFFFFF);

/// The part of a selected entity's chrome under a pointer.
enum EntitySelectionHit {
  /// The frame or the entity inside it.
  frame,

  /// The handle on the left side.
  leftHandle,

  /// The handle on the right side.
  rightHandle,
}

/// By-value snapshot of an [EntityLayer]'s mutable state. Captured at
/// tool-open by [EntityLayer.saveSnapshot], consumed on cancel by
/// [EntityLayer.restoreSnapshot].
class EntitySnapshot {
  EntitySnapshot._({
    required this.entities,
    required this.selected,
    required this.editing,
    required this.style,
    required this.align,
    required this.colour,
    required this.fontSize,
  });

  /// Copies of the entities.
  final List<TextEntity> entities;
  /// Id of the selected entity.
  final String? selected;
  /// Id of the entity under keyboard edit.
  final String? editing;
  /// The pending style.
  final TextEntityStyle style;
  /// The pending alignment.
  final TextAlign align;
  /// The pending colour.
  final Color colour;
  /// The pending font size.
  final double fontSize;
}

/// Overlay-entity layer: [TextEntity] instances in source-image space.
///
/// The layer needs the source image only for its metrics — the
/// [TextEntity.displayFontSize] reference and [exportSize] — so it is
/// constructed with [imageSize] and holds no `ui.Image`.
class EntityLayer with Emitter, Painter, Exporter {
  /// A layer over a source image of [imageSize].
  EntityLayer({required this.imageSize});

  /// The source image's size in pixels.
  final Size imageSize;

  /// The overlays, bottom to top.
  final List<TextEntity> entities = <TextEntity>[];

  String? _selected;
  String? _editing;

  /// Id of the entity [hitTestSelection] tests its chrome against.
  String? get selected => _selected;

  /// Id of the entity under keyboard edit. [paintEntitiesOnly] skips it, so
  /// the live overlay is that string's only rendering.
  String? get editing => _editing;

  set editing(String? id) {
    if (_editing == id) return;
    _editing = id;
    notifyListeners();
  }

  /// The style a fresh layer's next insert takes.
  static const TextEntityStyle defaultStyle = TextEntityStyle.filled;
  /// The alignment a fresh layer's next insert takes.
  static const TextAlign defaultAlign = TextAlign.center;
  /// The colour a fresh layer's next insert takes.
  static const Color defaultColour = Color(0xFFFFFFFF);
  /// The font size a fresh layer's next insert takes.
  static const double defaultFontSize = 0.08;

  /// The style the next insert takes.
  TextEntityStyle pendingStyle = defaultStyle;
  /// The alignment the next insert takes.
  TextAlign pendingAlign = defaultAlign;
  /// The colour the next insert takes.
  Color pendingColour = defaultColour;
  /// The font size the next insert takes.
  double pendingFontSize = defaultFontSize;

  EntitySnapshot? _snapshot;
  TextEntity? _preEdit;

  /// The entity with [id]; absent when none has it.
  TextEntity? byId(String? id) {
    for (final entity in entities) {
      if (entity.id == id) return entity;
    }
    return null;
  }

  /// The selected entity.
  TextEntity? get selectedEntity => byId(_selected);

  /// The entity under keyboard edit.
  TextEntity? get editingEntity => byId(_editing);

  /// Whether the layer holds any entity.
  bool get hasAppliedEdits => entities.isNotEmpty;

  /// Adds [entity] on top.
  void add(TextEntity entity) {
    entities.add(entity);
    notifyListeners();
  }

  /// Removes the entity with [id], with its selection and edit.
  void remove(String id) {
    if (!entities.any((e) => e.id == id)) return;
    entities.removeWhere((e) => e.id == id);
    if (_selected == id) _selected = null;
    if (_editing == id) _editing = null;
    notifyListeners();
  }

  /// Selects the entity with [id].
  void select(String id) {
    if (_selected == id) return;
    _selected = id;
    notifyListeners();
  }

  /// Clears the selection.
  void deselect() {
    if (_selected == null) return;
    _selected = null;
    notifyListeners();
  }

  /// Add [entity], select it and open the keyboard editor on it.
  /// [cancelEdit] removes it again.
  void insertAndEdit(TextEntity entity) {
    entities.add(entity);
    _selected = entity.id;
    _preEdit = null;
    _editing = entity.id;
    notifyListeners();
  }

  /// Open the keyboard editor on the existing entity [id] and select it.
  /// [cancelEdit] restores the copy taken here.
  void beginEdit(String id) {
    final entity = byId(id);
    if (entity == null) return;
    _preEdit = entity.copyWith();
    _selected = id;
    _editing = id;
    notifyListeners();
  }

  /// Close the editor keeping what was typed. An empty string removes the
  /// entity; anything else stays selected.
  void endEdit() {
    final entity = byId(_editing);
    if (entity == null) return;
    _editing = null;
    _preEdit = null;
    if (entity.text.isEmpty) {
      remove(entity.id);
      return;
    }
    notifyListeners();
  }

  /// Close the editor, restoring the copy [beginEdit] took or removing the
  /// entity [insertAndEdit] created.
  void cancelEdit() {
    final id = _editing;
    if (id == null) return;
    final previous = _preEdit;
    _editing = null;
    _preEdit = null;
    if (previous == null) {
      remove(id);
      return;
    }
    entities[entities.indexWhere((e) => e.id == id)] = previous;
    notifyListeners();
  }

  /// Apply [change] to the entity with [id] and emit.
  void update(String id, void Function(TextEntity entity) change) {
    final entity = byId(id);
    if (entity == null) return;
    change(entity);
    notifyListeners();
  }

  /// The selected entity's attributes, or the pending ones the next insert
  /// takes.
  TextEntityStyle get activeStyle => selectedEntity?.style ?? pendingStyle;
  /// The selected entity's alignment, or the pending one.
  TextAlign get activeAlign => selectedEntity?.align ?? pendingAlign;
  /// The selected entity's colour, or the pending one.
  Color get activeColour => selectedEntity?.colour ?? pendingColour;
  /// The selected entity's font size, or the pending one.
  double get activeFontSize => selectedEntity?.fontSize ?? pendingFontSize;

  void _writeActive(
    void Function(TextEntity entity) toEntity,
    VoidCallback toPending,
  ) {
    final entity = selectedEntity;
    if (entity == null) {
      toPending();
    } else {
      toEntity(entity);
    }
    notifyListeners();
  }

  /// Moves the selected entity, or the pending style, to the next style.
  void cycleStyle() => _writeActive(
    (entity) => entity.style = entity.style.next,
    () => pendingStyle = pendingStyle.next,
  );

  /// Moves the selected entity, or the pending alignment, left to centre to
  /// right and around.
  void toggleAlignment() {
    TextAlign next(TextAlign align) => switch (align) {
      TextAlign.left => TextAlign.center,
      TextAlign.center => TextAlign.right,
      _ => TextAlign.left,
    };
    _writeActive(
      (entity) => entity.align = next(entity.align),
      () => pendingAlign = next(pendingAlign),
    );
  }

  /// Sets the selected entity's colour, or the pending one.
  void setColour(Color colour) => _writeActive(
    (entity) => entity.colour = colour,
    () => pendingColour = colour,
  );

  /// Sets the selected entity's font size, or the pending one.
  void setFontSize(double fontSize) => _writeActive(
    (entity) => entity.fontSize = fontSize,
    () => pendingFontSize = fontSize,
  );

  /// Capture current state for later [restoreSnapshot]. Entities are copied
  /// by value — they stay mutable while the tool is open.
  void saveSnapshot() {
    _snapshot = EntitySnapshot._(
      entities: [for (final e in entities) e.copyWith()],
      selected: _selected,
      editing: _editing,
      style: pendingStyle,
      align: pendingAlign,
      colour: pendingColour,
      fontSize: pendingFontSize,
    );
  }

  /// Restore the layer to the last [saveSnapshot]. No-op if none saved.
  void restoreSnapshot() {
    final s = _snapshot;
    if (s == null) return;
    entities
      ..clear()
      ..addAll([for (final e in s.entities) e.copyWith()]);
    _selected = s.selected;
    _editing = s.editing;
    pendingStyle = s.style;
    pendingAlign = s.align;
    pendingColour = s.colour;
    pendingFontSize = s.fontSize;
    notifyListeners();
  }

  /// Paint committed entities — glyphs and pills, no selection chrome — into
  /// a canvas whose coordinates are source-image pixels of size [reference].
  /// Skips [editing].
  void paintEntitiesOnly(Canvas canvas, Size reference) {
    for (final entity in entities) {
      if (entity.id == _editing) continue;
      paintTextEntity(canvas, entity, reference);
    }
  }

  @override
  void paintViewport(
    Canvas canvas,
    Size size, {
    required vmath.Matrix4 camera,
  }) {
    canvas.save();
    canvas.transform(camera.storage);
    paintEntitiesOnly(canvas, imageSize);
    canvas.restore();
  }

  @override
  Size get exportSize => imageSize;

  @override
  void paintExport(Canvas canvas, Size size) {
    paintEntitiesOnly(canvas, imageSize);
  }

  /// The topmost entity whose rotated + scaled layout bounds contain
  /// [sourcePoint].
  TextEntity? hitTest(Offset sourcePoint) {
    for (final entity in entities.reversed) {
      if (_bounds(entity).contains(_toEntityLocal(entity, sourcePoint))) {
        return entity;
      }
    }
    return null;
  }

  /// The chrome region of the selected entity under [sourcePoint], or null
  /// when nothing is selected or the point misses. Outset and handle targets
  /// are screen points divided by [cameraScale] — the product of the viewer
  /// and host camera scales — so they cover a constant on-screen area at any
  /// zoom.
  EntitySelectionHit? hitTestSelection(
    Offset sourcePoint, {
    required double cameraScale,
  }) {
    final entity = selectedEntity;
    if (entity == null) return null;

    final bounds = _bounds(entity);
    final local = _toEntityLocal(entity, sourcePoint);
    final handle = entitySelectionViewHandleSize / cameraScale;
    Rect handleAt(double x) =>
        Rect.fromCenter(center: Offset(x, 0), width: handle, height: handle);

    if (handleAt(bounds.left).contains(local)) {
      return EntitySelectionHit.leftHandle;
    }
    if (handleAt(bounds.right).contains(local)) {
      return EntitySelectionHit.rightHandle;
    }
    if (bounds
        .inflate(entitySelectionFrameOutset / cameraScale)
        .contains(local)) {
      return EntitySelectionHit.frame;
    }
    return null;
  }

  /// [entity]'s layout box at its scale, centred on the origin — the frame
  /// [_toEntityLocal] maps points into.
  Rect _bounds(TextEntity entity) {
    final layout = TextEntityLayout(entity, imageSize);
    final size = layout.size;
    layout.dispose();
    return Rect.fromCenter(
      center: Offset.zero,
      width: size.width * entity.scale,
      height: size.height * entity.scale,
    );
  }

  Offset _toEntityLocal(TextEntity entity, Offset sourcePoint) {
    final d = sourcePoint - entity.position;
    final cos = math.cos(-entity.rotation);
    final sin = math.sin(-entity.rotation);
    return Offset(d.dx * cos - d.dy * sin, d.dx * sin + d.dy * cos);
  }
}

/// Selection chrome: the selected entity's frame and its two side handles.
///
/// The entity's source bounds map through the same product
/// [DrawScenePainter] composes content with, and the strokes land in the
/// untransformed overlay canvas, so their widths are screen points at any
/// zoom.
class EntitySelectionPainter extends CustomPainter {
  /// Paints [layer]'s selection through the scene's transforms.
  EntitySelectionPainter({
    required this.layer,
    required this.camera,
    this.crop,
    this.viewerCamera,
  }) : super(
         repaint: Listenable.merge([layer, camera, ?crop, ?viewerCamera]),
       );

  /// The layer whose selection is painted.
  final EntityLayer layer;
  /// The host's image-to-viewport transform.
  final ValueListenable<vmath.Matrix4> camera;
  /// The crop the scene is shown through.
  final CropImageLayer? crop;
  /// The pinch and pan applied on top of [camera].
  final ValueListenable<vmath.Matrix4>? viewerCamera;

  @override
  void paint(Canvas canvas, Size size) {
    final entity = layer.selectedEntity;
    if (entity == null || layer.editing != null) return;

    final m = vmath.Matrix4.identity();
    final viewer = viewerCamera?.value;
    if (viewer != null) m.multiply(viewer);
    m.multiply(camera.value);
    final c = crop;
    if (c != null && c.hasAppliedEdits) {
      m
        ..translateByDouble(c.imageSize.width / 2, c.imageSize.height / 2, 0, 1)
        ..multiply(c.imageTransform.matrix)
        ..translateByDouble(
          -c.imageSize.width / 2,
          -c.imageSize.height / 2,
          0,
          1,
        );
    }

    final bounds = layer._bounds(entity);
    final cos = math.cos(entity.rotation);
    final sin = math.sin(entity.rotation);
    Offset at(double x, double y) {
      final source =
          entity.position + Offset(x * cos - y * sin, x * sin + y * cos);
      final v = vmath.Vector3(source.dx, source.dy, 0)..applyMatrix4(m);
      return Offset(v.x, v.y);
    }

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = entitySelectionStrokeWidth
      ..color = entitySelectionColour;
    canvas.drawPath(
      Path()..addPolygon([
        at(bounds.left, bounds.top),
        at(bounds.right, bounds.top),
        at(bounds.right, bounds.bottom),
        at(bounds.left, bounds.bottom),
      ], true),
      paint,
    );
    for (final centre in [at(bounds.left, 0), at(bounds.right, 0)]) {
      canvas.drawCircle(centre, entitySelectionViewHandleSize / 2, paint);
    }
  }

  @override
  bool shouldRepaint(covariant EntitySelectionPainter oldDelegate) =>
      layer != oldDelegate.layer ||
      camera != oldDelegate.camera ||
      crop != oldDelegate.crop ||
      viewerCamera != oldDelegate.viewerCamera;
}

/// Selection + manipulation surface for [layer], stacked as a sibling
/// above `DrawGestures`.
///
/// - **touch** an entity: select it and hand the strip to the text controls.
/// - **double tap** an entity: re-open the keyboard editor on it.
/// - **1 finger** on the selection: move it; on a side handle: scale +
///   rotate it about the frame centre.
/// - **2 fingers** on the selection: scale + rotate + move it.
/// - **long press** on the selection: the delete menu.
///
/// With nothing selected the surface is hittable only over an entity, so
/// every other pointer reaches `DrawGestures`. With a selection it is
/// hittable everywhere: a touch that starts off the entity clears the
/// selection and is consumed.
class EntityGestures extends StatefulWidget {
  /// Selects and manipulates [layer]'s entities through the scene's
  /// transforms.
  const EntityGestures({
    super.key,
    required this.layer,
    required this.hostCamera,
    required this.onSelect,
    required this.onDeselect,
    this.crop,
    this.viewerCamera,
  });

  /// The layer whose entities are manipulated.
  final EntityLayer layer;
  /// The host's image-to-viewport transform.
  final ValueListenable<vmath.Matrix4> hostCamera;
  /// The crop the scene is shown through.
  final CropImageLayer? crop;
  /// The pinch and pan applied on top of [hostCamera].
  final ValueListenable<vmath.Matrix4>? viewerCamera;

  /// Fired when a pointer selects an entity.
  final VoidCallback onSelect;

  /// Fired when a touch off the selection clears it.
  final VoidCallback onDeselect;

  @override
  State<EntityGestures> createState() => _EntityGesturesState();
}

enum _EntityDrag { move, handle, none }

class _EntityGesturesState extends State<EntityGestures> {
  final Set<int> _pointers = <int>{};
  _EntityDrag? _drag;
  bool _leftHandle = false;
  Offset _startSource = Offset.zero;
  Offset _startPosition = Offset.zero;
  double _startScale = 1;
  double _startRotation = 0;
  double _startFrameWidth = 1;
  Offset _doubleTapAt = Offset.zero;
  OverlayEntry? _menu;

  @override
  void dispose() {
    _dismissMenu();
    super.dispose();
  }

  Offset _toSource(Offset viewport) => toSourcePoint(
    viewport,
    hostCamera: widget.hostCamera.value,
    viewerCamera: widget.viewerCamera?.value,
    crop: widget.crop,
  );

  double _cameraScale() =>
      (widget.viewerCamera?.value.storage[0] ?? 1) *
      widget.hostCamera.value.storage[0];

  EntitySelectionHit? _chromeAt(Offset source) =>
      widget.layer.hitTestSelection(source, cameraScale: _cameraScale());

  bool _hits(Offset position) {
    final layer = widget.layer;
    if (layer.selected != null) return true;
    return layer.hitTest(_toSource(position)) != null;
  }

  void _select(TextEntity entity) {
    widget.layer.select(entity.id);
    widget.onSelect();
  }

  void _onDoubleTapDown(TapDownDetails e) => _doubleTapAt = e.localPosition;

  void _onDoubleTap() {
    final layer = widget.layer;
    final entity = layer.hitTest(_toSource(_doubleTapAt));
    if (entity == null) return;
    layer.beginEdit(entity.id);
    widget.onSelect();
  }

  void _onLongPressStart(LongPressStartDetails e) {
    final entity = widget.layer.selectedEntity;
    if (entity == null) return;
    if (_chromeAt(_toSource(e.localPosition)) == null) return;
    _showMenu(e.globalPosition, entity.id);
  }

  void _showMenu(Offset anchor, String id) {
    _dismissMenu();
    final entry = OverlayEntry(
      builder: (_) => _EntityMenu(
        anchor: anchor,
        onDelete: () {
          _dismissMenu();
          widget.layer.remove(id);
          widget.onDeselect();
        },
        onDismiss: _dismissMenu,
      ),
    );
    _menu = entry;
    Overlay.of(context).insert(entry);
  }

  void _dismissMenu() {
    _menu?.remove();
    _menu = null;
  }

  void _onPointerDown(PointerDownEvent e) {
    if (_pointers.isEmpty) _beginDrag(_toSource(e.localPosition));
    _pointers.add(e.pointer);
  }

  void _onPointerDone(PointerEvent e) {
    _pointers.remove(e.pointer);
    if (_pointers.isEmpty) _drag = null;
  }

  void _beginDrag(Offset source) {
    final layer = widget.layer;
    if (layer.selected == null) {
      final entity = layer.hitTest(source);
      if (entity == null) {
        _drag = _EntityDrag.none;
        return;
      }
      _select(entity);
      _drag = _EntityDrag.move;
      return;
    }
    switch (_chromeAt(source)) {
      case EntitySelectionHit.leftHandle:
      case EntitySelectionHit.rightHandle:
        _leftHandle = _chromeAt(source) == EntitySelectionHit.leftHandle;
        _drag = _EntityDrag.handle;
      case EntitySelectionHit.frame:
        _drag = _EntityDrag.move;
      case null:
        final entity = layer.hitTest(source);
        if (entity != null) {
          _select(entity);
          _drag = _EntityDrag.move;
          return;
        }
        layer.deselect();
        widget.onDeselect();
        _drag = _EntityDrag.none;
    }
  }

  void _anchor(Offset focal) {
    _startSource = _toSource(focal);
    final entity = widget.layer.selectedEntity;
    if (entity == null) return;
    _startPosition = entity.position;
    _startScale = entity.scale;
    _startRotation = entity.rotation;
    _startFrameWidth = widget.layer._bounds(entity).width;
  }

  void _onScaleUpdate(ScaleUpdateDetails e) {
    final layer = widget.layer;
    final entity = layer.selectedEntity;
    if (entity == null || _drag == null || _drag == _EntityDrag.none) return;
    final source = _toSource(e.localFocalPoint);

    if (_drag == _EntityDrag.handle) {
      final d = source - _startSource;
      final cos = math.cos(-_startRotation);
      final sin = math.sin(-_startRotation);
      final dx = (d.dx * cos - d.dy * sin) * (_leftHandle ? -1 : 1);
      final scaleDelta = (_startFrameWidth + dx * 2) / _startFrameWidth;
      final from = _startSource - _startPosition;
      final to = source - _startPosition;
      layer.update(entity.id, (target) {
        target.scale = math.max(0.01, _startScale * scaleDelta);
        target.rotation =
            _startRotation +
            math.atan2(to.dy, to.dx) -
            math.atan2(from.dy, from.dx);
      });
      return;
    }

    layer.update(entity.id, (target) {
      target.position = _startPosition + (source - _startSource);
      target.scale = math.max(0.01, _startScale * e.scale);
      target.rotation = _startRotation + e.rotation;
    });
  }

  @override
  Widget build(BuildContext context) {
    return _EntityHitGate(
      hits: _hits,
      child: Listener(
        onPointerDown: _onPointerDown,
        onPointerUp: _onPointerDone,
        onPointerCancel: _onPointerDone,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onDoubleTapDown: _onDoubleTapDown,
          onDoubleTap: _onDoubleTap,
          onLongPressStart: _onLongPressStart,
          onScaleStart: (e) => _anchor(e.localFocalPoint),
          onScaleUpdate: _onScaleUpdate,
        ),
      ),
    );
  }
}

/// Admits pointers to its child only where [hits] holds; everything else
/// falls through to the sibling below.
class _EntityHitGate extends SingleChildRenderObjectWidget {
  const _EntityHitGate({required this.hits, required Widget super.child});

  final bool Function(Offset position) hits;

  @override
  _RenderEntityHitGate createRenderObject(BuildContext context) =>
      _RenderEntityHitGate(hits);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderEntityHitGate renderObject,
  ) {
    renderObject.hits = hits;
  }
}

class _RenderEntityHitGate extends RenderProxyBox {
  _RenderEntityHitGate(this.hits);

  bool Function(Offset position) hits;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!size.contains(position) || !hits(position)) return false;
    hitTestChildren(result, position: position);
    result.add(BoxHitTestEntry(this, position));
    return true;
  }
}

class _EntityMenu extends StatelessWidget {
  const _EntityMenu({
    required this.anchor,
    required this.onDelete,
    required this.onDismiss,
  });

  final Offset anchor;
  final VoidCallback onDelete;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onDismiss,
          ),
        ),
        Positioned(
          left: anchor.dx,
          top: anchor.dy,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(radius.md),
            ),
            child: Touch(
              onPress: onDelete,
              padding: EdgeInsets.symmetric(
                horizontal: space.lg,
                vertical: space.md,
              ),
              child: Text(
                strings.delete,
                style: text.body.copyWith(color: colors.destructive),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
