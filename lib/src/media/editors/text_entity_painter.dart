import 'dart:math' as math;

import 'package:ux/src/media/design.dart';
import 'package:ux/src/media/editors/text_entity.dart';
import 'package:ux/src/media/editors/text_pill.dart';
import 'package:flutter/painting.dart';

/// Far enough outside any line to resolve to that line's first and last
/// character.
const _beyondLine = 1e6;

/// A laid-out line. [pill] is [box] widened by the horizontal padding on each
/// edge.
typedef TextEntityLine = ({Rect box, Rect pill});

/// One [TextEntity]'s string laid out in entity-local coordinates, spanning
/// [size] with the glyphs inset by [padding] on the left.
class TextEntityLayout {
  /// Lays out [entity] against the source image [reference].
  factory TextEntityLayout(TextEntity entity, Size reference) {
    final fontSize = entity.displayFontSize(reference);
    final padding = (fontSize * 0.24).floorToDouble();
    final wrapWidth = math.max(0.0, entity.width - 2 * padding);
    final resolved = entity.style.resolve(entity.colour);
    final base = TextStyle(
      fontFamily: mediaFontFamily,
      fontSize: fontSize,
      fontWeight: FontWeight.w600,
    );

    TextPainter lay(TextStyle style) => TextPainter(
      text: TextSpan(text: entity.text, style: style),
      textAlign: entity.align,
      textDirection: TextDirection.ltr,
    )..layout(minWidth: wrapWidth, maxWidth: wrapWidth);

    final glyphs = lay(
      base.copyWith(
        color: resolved.textColor,
        shadows: entity.style == TextEntityStyle.regular
            ? const [
                Shadow(
                  offset: Offset(0, 4),
                  blurRadius: 4,
                  color: Color(0x66000000),
                ),
              ]
            : null,
      ),
    );

    final strokeWidth = fontSize / 9;
    final strokeColor = resolved.strokeColor;
    final outline = strokeColor == null
        ? null
        : lay(
            base.copyWith(
              foreground: Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = strokeWidth
                ..strokeJoin = StrokeJoin.round
                ..color = strokeColor,
            ),
          );

    return TextEntityLayout._(
      glyphs: glyphs,
      outline: outline,
      fontSize: fontSize,
      padding: padding,
      strokeWidth: strokeWidth,
      frameColor: resolved.frameColor,
      lines: _lines(glyphs, entity, padding),
    );
  }

  TextEntityLayout._({
    required this._glyphs,
    required this._outline,
    required this.fontSize,
    required this.padding,
    required this.strokeWidth,
    required this.frameColor,
    required this.lines,
  });

  final TextPainter _glyphs;
  final TextPainter? _outline;

  /// [TextEntity.displayFontSize] against the source image.
  final double fontSize;

  /// Horizontal inset of the glyphs from each edge.
  final double padding;

  /// Width of the outline a stroke style draws.
  final double strokeWidth;

  /// Colour of the frame behind the lines; absent when the style has none.
  final Color? frameColor;

  /// The non-empty lines, top to bottom.
  final List<TextEntityLine> lines;

  /// The glyphs' extent widened by [padding] on both sides.
  Size get size => Size(_glyphs.width + 2 * padding, _glyphs.height);

  /// The frame: the lines' pills joined into one outline.
  late final Path pillPath = textPillPath([for (final l in lines) l.pill]);

  /// Paints the frame, the outline and the glyphs at the origin.
  void paint(Canvas canvas) {
    if (frameColor != null) {
      canvas.drawPath(pillPath, Paint()..color = frameColor!);
    }
    _outline?.paint(canvas, Offset(padding, 0));
    _glyphs.paint(canvas, Offset(padding, 0));
  }

  /// Releases the text painters.
  void dispose() {
    _glyphs.dispose();
    _outline?.dispose();
  }
}

List<TextEntityLine> _lines(
  TextPainter glyphs,
  TextEntity entity,
  double padding,
) {
  final lines = <TextEntityLine>[];
  for (final metrics in glyphs.computeLineMetrics()) {
    final top = metrics.baseline - metrics.ascent;
    final middle = top + metrics.height / 2;
    final start = glyphs
        .getPositionForOffset(Offset(-_beyondLine, middle))
        .offset;
    final end = glyphs.getPositionForOffset(Offset(_beyondLine, middle)).offset;
    final text = entity.text.substring(start, end);
    if (text.isEmpty) continue;

    final box = Rect.fromLTWH(metrics.left, top, metrics.width, metrics.height);
    var usedRight = box.right;
    if (text.endsWith(' ') && entity.align != TextAlign.right) {
      // LineMetrics drops a trailing space; the selection box still carries it.
      final boxes = glyphs.getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: end),
      );
      if (boxes.isNotEmpty) {
        usedRight = boxes.map((b) => b.toRect().right).reduce(math.max);
      }
      usedRight -= (metrics.height * 0.145).floorToDouble();
    }
    lines.add((
      box: box,
      pill: Rect.fromLTRB(box.left, top, usedRight + 2 * padding, box.bottom),
    ));
  }
  return lines;
}

/// Paints [entity] into a canvas whose coordinates are source-image pixels.
void paintTextEntity(Canvas canvas, TextEntity entity, Size reference) {
  final layout = TextEntityLayout(entity, reference);
  canvas
    ..save()
    ..translate(entity.position.dx, entity.position.dy)
    ..rotate(entity.rotation)
    ..scale(entity.scale)
    ..translate(-layout.size.width / 2, -layout.size.height / 2);
  layout.paint(canvas);
  canvas.restore();
  layout.dispose();
}
