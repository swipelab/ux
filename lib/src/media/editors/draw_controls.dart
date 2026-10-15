import 'package:ux/src/media/design.dart';
import 'package:ux/src/media/editors/draw_image_layer.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:ux/src/media/touch.dart';

/// Height of a brush in the picker at rest.
const double kDrawToolHeight = 100;

/// How much taller the selected brush stands.
const double kDrawToolElevation = 16;
const double _toolSlotWidth = 32;

const double _swatchInner = 22;
const double _swatchOuter = 32;

const Color _eraserTipColor = Color(0xFFFFB7C5);

const double _toolWidth = 28;

/// Hand-authored SVG illustration per brush. Each asset has gradients,
/// layered shading, and `currentColor` on the tinted parts (tip + ferrule
/// + arrow glyph) so [SvgTheme.currentColor] swaps the brush tint at
/// render time.
String _toolAsset(BrushType t) => switch (t) {
  BrushType.pen => 'packages/ux/assets/draw_tools/tool_pen.svg',
  BrushType.arrow => 'packages/ux/assets/draw_tools/tool_arrow.svg',
  BrushType.marker => 'packages/ux/assets/draw_tools/tool_marker.svg',
  BrushType.neon => 'packages/ux/assets/draw_tools/tool_neon.svg',
  BrushType.eraser => 'packages/ux/assets/draw_tools/tool_eraser.svg',
};

/// Position of the thickness-indicator band on each tool body, expressed
/// as fractions of the tool's rendered height (which corresponds to the
/// SVG's 350-unit viewBox). Eraser has no band.
typedef _BandRatios = ({double top, double height});
const Map<BrushType, _BandRatios> _bandRatios = {
  BrushType.pen: (top: 140 / 350, height: 36 / 350),
  BrushType.arrow: (top: 140 / 350, height: 36 / 350),
  BrushType.marker: (top: 140 / 350, height: 36 / 350),
  BrushType.neon: (top: 94 / 350, height: 36 / 350),
};

/// Bottom control strip for the draw tool. Three rows top → bottom:
/// brush picker, color row (rainbow + 8 swatches + plus), action row
/// (cancel circle + Draw/Text segmented + check circle).
class DrawControls extends StatelessWidget {
  /// Shows [layer]'s brush state and binds the actions to their callbacks.
  const DrawControls({
    super.key,
    required this.layer,
    required this.onCancel,
    required this.onSubmit,
    required this.onText,
  });

  /// The layer whose brush, colour and strokes the strip edits.
  final DrawImageLayer layer;

  /// Leaves the tool without applying.
  final VoidCallback onCancel;

  /// Applies the strokes.
  final VoidCallback onSubmit;

  /// Switches to the text tool.
  final VoidCallback onText;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: space.md, vertical: space.sm),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          BrushTypePicker(layer: layer),
          DrawColorRow(
            selected: layer.currentColor,
            onSelect: layer.setCurrentColor,
          ),
          SizedBox(height: space.md),
          EditorActionRow(
            mode: EditorMode.draw,
            onCancel: onCancel,
            onSubmit: onSubmit,
            onDraw: layer.strokes.isEmpty ? null : layer.undo,
            onText: onText,
          ),
        ],
      ),
    );
  }
}

/// The row of brushes; the selected one stands taller, and the row fades out
/// at its foot.
class BrushTypePicker extends StatelessWidget {
  /// Picks [layer]'s brush.
  const BrushTypePicker({super.key, required this.layer});

  /// The layer whose brush is picked.
  final DrawImageLayer layer;

  @override
  Widget build(BuildContext context) {
    const pickerHeight = kDrawToolHeight + kDrawToolElevation;
    const fadeLength = 16.0;
    const fadeStart = (pickerHeight - fadeLength) / pickerHeight;
    return ShaderMask(
      shaderCallback: (bounds) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: const [Color(0xFFFFFFFF), Color(0xFFFFFFFF), Color(0x00FFFFFF)],
        stops: [0.0, fadeStart, 1.0],
      ).createShader(bounds),
      blendMode: BlendMode.dstIn,
      child: SizedBox(
        height: pickerHeight,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final type in BrushType.values)
              _BrushTool(layer: layer, type: type),
          ],
        ),
      ),
    );
  }
}

class _BrushTool extends StatelessWidget {
  const _BrushTool({required this.layer, required this.type});

  final DrawImageLayer layer;
  final BrushType type;

  @override
  Widget build(BuildContext context) {
    final selected = layer.currentBrush == type;
    final tip = type == BrushType.eraser
        ? _eraserTipColor
        : layer.brushColors[type]!;
    final h = selected ? kDrawToolHeight + kDrawToolElevation : kDrawToolHeight;
    final band = _bandRatios[type];
    return Touch(
      onPress: () => layer.setBrushType(type),
      child: SizedBox(
        width: _toolSlotWidth,
        height: kDrawToolHeight + kDrawToolElevation,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: AnimatedSize(
            duration: kAnimation,
            curve: Curves.easeOut,
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              width: _toolWidth,
              height: h,
              child: Stack(
                children: [
                  SvgPicture.asset(
                    _toolAsset(type),
                    width: _toolWidth,
                    height: h,
                    fit: BoxFit.fill,
                    theme: SvgTheme(currentColor: tip),
                  ),
                  if (band != null)
                    _ThicknessBand(
                      width: _toolWidth,
                      height: h,
                      color: tip,
                      thickness: layer.normalizedThickness,
                      topRatio: band.top,
                      maxHeightRatio: band.height,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Selected-color band on the body that shrinks/grows with brush size.
/// Top-anchored. The `0.08 + 0.92 * t` floor keeps the band visible at
/// the minimum thickness so the brush stays recognizable.
class _ThicknessBand extends StatelessWidget {
  const _ThicknessBand({
    required this.width,
    required this.height,
    required this.color,
    required this.thickness,
    required this.topRatio,
    required this.maxHeightRatio,
  });

  final double width;
  final double height;
  final Color color;
  final double thickness;
  final double topRatio;
  final double maxHeightRatio;

  @override
  Widget build(BuildContext context) {
    final factor = 0.08 + 0.92 * thickness;
    final maxBandHeight = height * maxHeightRatio;
    final bandHeight = maxBandHeight * factor;
    final bandTop = height * topRatio;
    final bandLeft = width * 0.14;
    final bandWidth = width * 0.72;

    return Positioned(
      top: bandTop,
      left: bandLeft,
      width: bandWidth,
      height: bandHeight,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              color.withValues(alpha: 0.45),
              color,
              color,
              color.withValues(alpha: 0.45),
            ],
            stops: const [0.0, 0.18, 0.82, 1.0],
          ),
        ),
      ),
    );
  }
}

/// The colour row: the rainbow swatch, the palette, the add button.
class DrawColorRow extends StatelessWidget {
  /// Marks [selected] and reports a pick through [onSelect].
  const DrawColorRow({
    super.key,
    required this.selected,
    required this.onSelect,
  });

  /// The colour marked as chosen.
  final Color selected;

  /// Called with the colour picked.
  final ValueChanged<Color> onSelect;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const _RainbowSwatch(),
        SizedBox(width: space.xs),
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (final c in kDrawPalette)
                _PaletteSwatch(
                  color: c,
                  selected: selected == c,
                  onPress: () => onSelect(c),
                ),
            ],
          ),
        ),
        SizedBox(width: space.xs),
        const _AddColorButton(),
      ],
    );
  }
}

class _RainbowSwatch extends StatelessWidget {
  const _RainbowSwatch();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _swatchOuter,
      height: _swatchOuter,
      child: Center(
        child: SizedBox(
          width: _swatchInner,
          height: _swatchInner,
          child: CustomPaint(painter: _RainbowSwatchPainter()),
        ),
      ),
    );
  }
}

class _RainbowSwatchPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide / 2;
    final c = size.center(Offset.zero);
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = const SweepGradient(
          colors: [
            Color(0xFFFF3B30),
            Color(0xFFFFCC00),
            Color(0xFF34C759),
            Color(0xFF5AC8FA),
            Color(0xFF0A84FF),
            Color(0xFFAF52DE),
            Color(0xFFFF3B30),
          ],
        ).createShader(Rect.fromCircle(center: Offset.zero, radius: 1)),
    );
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..color = const Color(0xFFFFFFFF)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_RainbowSwatchPainter old) => false;
}

class _AddColorButton extends StatelessWidget {
  const _AddColorButton();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _swatchOuter,
      height: _swatchOuter,
      child: Center(
        child: Icon(CupertinoIcons.plus, color: colors.onMedia, size: 22),
      ),
    );
  }
}

class _PaletteSwatch extends StatelessWidget {
  const _PaletteSwatch({
    required this.color,
    required this.selected,
    required this.onPress,
  });

  final Color color;
  final bool selected;
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) {
    return Touch(
      fade: 0.5,
      onPress: onPress,
      child: SizedBox(
        width: _swatchOuter,
        height: _swatchOuter,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (selected)
              Container(
                width: _swatchOuter - 2,
                height: _swatchOuter - 2,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: colors.onMedia, width: 1.5),
                ),
              ),
            Container(
              width: _swatchInner,
              height: _swatchInner,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color,
                border: Border.all(
                  color: colors.onMedia.withValues(alpha: 0.15),
                  width: 1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Cancel · [ModeSegmented] pill · submit, shared by the draw and text
/// strips.
class EditorActionRow extends StatelessWidget {
  /// Shows [mode] as active between the cancel and submit buttons.
  const EditorActionRow({
    super.key,
    required this.mode,
    required this.onCancel,
    required this.onSubmit,
    required this.onDraw,
    required this.onText,
  });

  /// The active strip.
  final EditorMode mode;

  /// Called by the cancel button.
  final VoidCallback onCancel;

  /// Called by the submit button.
  final VoidCallback onSubmit;

  /// A press on the Draw segment.
  final VoidCallback? onDraw;

  /// A press on the Text segment.
  final VoidCallback? onText;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _CircleBtn(icon: CupertinoIcons.xmark, onPress: onCancel),
        SizedBox(width: space.sm),
        Expanded(
          child: ModeSegmented(mode: mode, onDraw: onDraw, onText: onText),
        ),
        SizedBox(width: space.sm),
        _CircleBtn(icon: CupertinoIcons.checkmark, onPress: onSubmit),
      ],
    );
  }
}

class _CircleBtn extends StatelessWidget {
  const _CircleBtn({required this.icon, required this.onPress});

  final IconData icon;
  final VoidCallback onPress;

  @override
  Widget build(BuildContext context) {
    return Touch(
      onPress: onPress,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: colors.onMedia, width: 1.5),
        ),
        child: Center(child: Icon(icon, color: colors.onMedia, size: 18)),
      ),
    );
  }
}

/// Which control strip the draw editor shows.
enum EditorMode {
  /// The brush strip.
  draw,

  /// The text strip.
  text,
}

/// "Draw / Text" pill. [mode]'s segment is the filled one.
/// Tapping the active Draw segment is Undo — the only undo affordance
/// on this strip.
class ModeSegmented extends StatelessWidget {
  /// Fills [mode]'s segment.
  const ModeSegmented({
    super.key,
    required this.mode,
    required this.onDraw,
    required this.onText,
  });

  /// The segment that is filled.
  final EditorMode mode;

  /// A press on the Draw segment; the inactive segment takes none when
  /// absent.
  final VoidCallback? onDraw;

  /// A press on the Text segment; the inactive segment takes none when
  /// absent.
  final VoidCallback? onText;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: const Color(0x55000000),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          _ModeSegment(
            label: 'Draw',
            active: mode == EditorMode.draw,
            onPress: onDraw,
          ),
          _ModeSegment(
            label: 'Text',
            active: mode == EditorMode.text,
            onPress: onText,
          ),
        ],
      ),
    );
  }
}

class _ModeSegment extends StatelessWidget {
  const _ModeSegment({
    required this.label,
    required this.active,
    required this.onPress,
  });

  final String label;
  final bool active;
  final VoidCallback? onPress;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      label,
      style: TextStyle(
        color: active ? colors.onMedia : colors.onMedia.withValues(alpha: 0.5),
        fontWeight: active ? FontWeight.w600 : null,
        fontSize: 14,
      ),
    );
    final content = active
        ? Container(
            margin: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: const Color(0x33FFFFFF),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Center(child: text),
          )
        : Center(child: text);
    return Expanded(
      child: active || onPress != null
          ? Touch(onPress: onPress, child: content)
          : content,
    );
  }
}

/// Vertical 0–1 slider that floats on the left edge of the editor area.
class BrushSizeSlider extends StatelessWidget {
  /// Shows [value] and reports a tap or a drag through [onChanged].
  const BrushSizeSlider({
    super.key,
    required this.value,
    required this.colour,
    required this.onChanged,
  });

  static const double _width = 22;
  static const double _height = 220;
  static const double _padTop = 12;
  static const double _padBottom = 12;
  static const double _trackWidth = 2;
  static const double _thumbSize = 12;

  /// Where the thumb sits on the track, 0 at the bottom.
  final double value;

  /// Track fill below the thumb.
  final Color colour;

  /// Called with the value under a tap or a drag.
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: EdgeInsets.only(left: space.xs),
        child: SizedBox(
          width: _width,
          height: _height,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: (e) => _drag(e.localPosition.dy),
            onTapDown: (e) => _drag(e.localPosition.dy),
            child: Stack(
              alignment: Alignment.center,
              children: [
                Positioned(
                  top: _padTop,
                  bottom: _padBottom,
                  child: Container(
                    width: _trackWidth,
                    decoration: BoxDecoration(
                      color: const Color(0x33FFFFFF),
                      borderRadius: BorderRadius.circular(_trackWidth / 2),
                    ),
                  ),
                ),
                Positioned(
                  bottom: _padBottom,
                  child: Container(
                    width: _trackWidth,
                    height: (_height - _padTop - _padBottom) * value,
                    decoration: BoxDecoration(
                      color: colour,
                      borderRadius: BorderRadius.circular(_trackWidth / 2),
                    ),
                  ),
                ),
                Positioned(
                  bottom:
                      _padBottom +
                      (_height - _padTop - _padBottom) * value -
                      _thumbSize / 2,
                  child: Container(
                    width: _thumbSize,
                    height: _thumbSize,
                    decoration: BoxDecoration(
                      color: colors.onMedia,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0x44000000),
                          blurRadius: 3,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _drag(double localY) {
    final track = _height - _padTop - _padBottom;
    onChanged((1.0 - ((localY - _padTop) / track)).clamp(0.0, 1.0));
  }
}
