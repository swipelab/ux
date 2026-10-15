import 'package:ux/src/media/design.dart';
import 'package:ux/src/media/editors/draw_controls.dart';
import 'package:ux/src/media/editors/text_entity.dart';
import 'package:flutter/cupertino.dart';
import 'package:ux/src/media/touch.dart';

/// Bottom control strip for the text tool. Three rows top → bottom:
/// style + alignment buttons, color row, action row. Every row matches
/// its [DrawControls] counterpart's height, so swapping modes leaves the
/// measured chrome height — and with it the host camera's fit — alone.
class TextControls extends StatelessWidget {
  /// Shows the text tool's state and binds each control to its callback.
  const TextControls({
    super.key,
    required this.style,
    required this.align,
    required this.colour,
    required this.onStyle,
    required this.onAlign,
    required this.onColour,
    required this.onDraw,
    required this.onText,
    required this.onCancel,
    required this.onSubmit,
  });

  /// The style the style button previews.
  final TextEntityStyle style;

  /// The alignment the alignment button shows.
  final TextAlign align;

  /// The colour selected in the colour row.
  final Color colour;

  /// Moves to the next style.
  final VoidCallback onStyle;

  /// Moves to the next alignment.
  final VoidCallback onAlign;

  /// Selects a colour.
  final ValueChanged<Color> onColour;

  /// Switches to the draw tool.
  final VoidCallback onDraw;

  /// A press on the text mode, the one that is active.
  final VoidCallback onText;

  /// Leaves the tool without applying.
  final VoidCallback onCancel;

  /// Applies the edits.
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: space.md, vertical: space.sm),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: kDrawToolHeight + kDrawToolElevation,
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextStyleButton(
                    style: style,
                    colour: colour,
                    onPress: onStyle,
                  ),
                  SizedBox(width: space.sm),
                  TextAlignButton(align: align, onPress: onAlign),
                ],
              ),
            ),
          ),
          DrawColorRow(selected: colour, onSelect: onColour),
          SizedBox(height: space.md),
          EditorActionRow(
            mode: EditorMode.text,
            onCancel: onCancel,
            onSubmit: onSubmit,
            onDraw: onDraw,
            onText: onText,
          ),
        ],
      ),
    );
  }
}

/// Cycles [TextEntityStyle], previewing the active one: "Aa" through the
/// same [TextEntityStyle.resolve] the entity paints with — frame as the
/// chip's fill, outline under the glyphs.
class TextStyleButton extends StatelessWidget {
  /// Previews [style] in [colour].
  const TextStyleButton({
    super.key,
    required this.style,
    required this.colour,
    required this.onPress,
  });

  static const double _fontSize = 17;

  /// The style previewed.
  final TextEntityStyle style;

  /// The colour the preview resolves [style] with.
  final Color colour;

  /// Called on a press.
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) {
    final resolved = style.resolve(colour);
    final outline = resolved.strokeColor;
    final base = TextStyle(
      fontFamily: mediaFontFamily,
      fontSize: _fontSize,
      fontWeight: FontWeight.w600,
    );
    return _Chip(
      onPress: onPress,
      color: resolved.frameColor,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (outline != null)
            Text(
              'Aa',
              style: base.copyWith(
                foreground: Paint()
                  ..style = PaintingStyle.stroke
                  ..strokeWidth = _fontSize / 9
                  ..strokeJoin = StrokeJoin.round
                  ..color = outline,
              ),
            ),
          Text('Aa', style: base.copyWith(color: resolved.textColor)),
        ],
      ),
    );
  }
}

/// Cycles left → centre → right, showing the active alignment.
class TextAlignButton extends StatelessWidget {
  /// Shows [align].
  const TextAlignButton({
    super.key,
    required this.align,
    required this.onPress,
  });

  /// The alignment shown.
  final TextAlign align;

  /// Called on a press.
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) {
    return _Chip(
      onPress: onPress,
      child: Icon(
        switch (align) {
          TextAlign.left => CupertinoIcons.text_alignleft,
          TextAlign.right => CupertinoIcons.text_alignright,
          _ => CupertinoIcons.text_aligncenter,
        },
        color: colors.onMedia,
        size: 20,
      ),
    );
  }
}

const Color _chipColour = Color(0x55000000);

class _Chip extends StatelessWidget {
  const _Chip({required this.onPress, required this.child, this.color});

  final VoidCallback onPress;
  final Widget child;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Touch(
      onPress: onPress,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: color ?? _chipColour,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Center(child: child),
      ),
    );
  }
}
