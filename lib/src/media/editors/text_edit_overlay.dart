import 'dart:math' as math;

import 'package:ux/src/media/design.dart';
import 'package:ux/src/media/editors/crop_image_layer.dart';
import 'package:ux/src/media/editors/editor_insets.dart';
import 'package:ux/src/media/editors/entity_layer.dart';
import 'package:ux/src/media/editors/text_entity.dart';
import 'package:ux/src/media/editors/text_entity_painter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:ux/ux.dart';
import 'package:vector_math/vector_math_64.dart' as vmath;

/// Dim behind the string under edit.
const Color _fadeColour = Color(0x66000000);

/// Live keyboard editor for the entity [entities] is editing: a fade over the
/// canvas with the string typed straight into place above the control strip.
///
/// The string is laid out in source-image pixels — the same
/// [TextEntityLayout] the committed entity paints through — and presented at
/// [TextEntity.scale] × viewer × host × crop scale by a [FittedBox].
class TextEditOverlay extends StatefulWidget {
  /// Edits the entity [entities] has under edit.
  const TextEditOverlay({
    super.key,
    required this.entities,
    required this.chromeHeight,
    required this.camera,
    required this.onDone,
    this.viewerCamera,
    this.crop,
  });

  /// The layer whose entity under edit is typed into; absent shows nothing.
  final EntityLayer? entities;

  /// Measured height of the bottom control strip, subtracted from the band
  /// the string is centred in.
  final ValueListenable<double> chromeHeight;

  /// The host's image-to-screen transform.
  final ValueListenable<vmath.Matrix4> camera;

  /// The draw screen's pinch and pan on top of [camera].
  final ValueListenable<vmath.Matrix4>? viewerCamera;

  /// The crop the image is shown through; its scale joins the presentation.
  final CropImageLayer? crop;

  /// Fired by a tap on the fade.
  final VoidCallback onDone;

  @override
  State<TextEditOverlay> createState() => _TextEditOverlayState();
}

class _TextEditOverlayState extends State<TextEditOverlay> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();
  String? _editingId;
  VoidCallback? _unsubscribe;

  @override
  void initState() {
    super.initState();
    _unsubscribe = widget.entities?.subscribe(_syncEditing);
  }

  @override
  void dispose() {
    _unsubscribe?.call();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _syncEditing() {
    final id = widget.entities?.editing;
    if (id == _editingId) return;
    _editingId = id;
    final text = widget.entities?.byId(id)?.text;
    if (text == null) return;
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final entities = widget.entities;
    if (entities == null) return SizedBox.shrink();
    return ListenableBuilder(
      listenable: Listenable.merge([
        entities,
        widget.chromeHeight,
        widget.camera,
        ?widget.viewerCamera,
        ?widget.crop,
        editorInsets,
      ]),
      builder: (context, _) {
        final entity = entities.editingEntity;
        if (entity == null) return SizedBox.shrink();
        return Positioned.fill(child: _scene(entities, entity));
      },
    );
  }

  Widget _scene(EntityLayer entities, TextEntity entity) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final top = editorSafeAreaTop;
        final bottom =
            constraints.maxHeight -
            widget.chromeHeight.value -
            editorKeyboardLift;
        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onDone,
                child: ColoredBox(color: _fadeColour),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: top,
              height: math.max(0.0, bottom - top),
              child: Center(child: _field(entities, entity)),
            ),
          ],
        );
      },
    );
  }

  Widget _field(EntityLayer entities, TextEntity entity) {
    final layout = TextEntityLayout(entity, entities.imageSize);
    final pill = layout.pillPath;
    final frame = layout.frameColor;
    final fontSize = layout.fontSize;
    final padding = layout.padding;
    final sourceHeight = layout.size.height;
    layout.dispose();

    var scale =
        entity.scale *
        (widget.viewerCamera?.value.storage[0] ?? 1) *
        widget.camera.value.storage[0];
    final crop = widget.crop;
    if (crop != null && crop.hasAppliedEdits) {
      scale *= crop.imageTransform.totalScale;
    }
    final resolved = entity.style.resolve(entity.colour);

    return SizedBox(
      width: entity.width * scale,
      height: sourceHeight * scale,
      child: FittedBox(
        fit: BoxFit.fill,
        child: SizedBox(
          width: entity.width,
          height: sourceHeight,
          child: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: TextEditPillPainter(path: pill, colour: frame),
                ),
              ),
              Positioned(
                left: padding,
                top: 0,
                width: entity.width - 2 * padding,
                child: EditableText(
                  controller: _controller,
                  focusNode: _focus,
                  autofocus: true,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  textAlign: entity.align,
                  style: TextStyle(
                    fontFamily: mediaFontFamily,
                    fontSize: fontSize,
                    fontWeight: FontWeight.w600,
                    color: resolved.textColor,
                  ),
                  // The committed TextPainter applies neither, and the pill
                  // is built on its glyph boxes.
                  strutStyle: StrutStyle.disabled,
                  textScaler: TextScaler.noScaling,
                  cursorColor: resolved.textColor,
                  backgroundCursorColor: const Color(0x00000000),
                  selectionColor: resolved.textColor.withValues(alpha: 0.3),
                  onChanged: (value) =>
                      entities.update(entity.id, (e) => e.text = value),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Paints the pill behind the string under edit, in source-image pixels.
class TextEditPillPainter extends CustomPainter {
  /// Fills [path] with [colour].
  const TextEditPillPainter({required this.path, required this.colour});

  /// The pill's outline.
  final Path path;

  /// The fill; absent paints nothing.
  final Color? colour;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = colour;
    if (fill == null) return;
    canvas.drawPath(path, Paint()..color = fill);
  }

  @override
  bool shouldRepaint(covariant TextEditPillPainter old) =>
      old.path != path || old.colour != colour;
}
