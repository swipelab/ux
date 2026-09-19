import 'dart:math' as math;
import 'dart:ui';

/// How a text overlay's colour is spent between glyphs, frame and outline.
enum TextEntityStyle {
  /// Glyphs in the colour, with a drop shadow.
  regular,
  /// A frame in the colour behind contrasting glyphs.
  filled,
  /// Glyphs in the colour over a translucent frame.
  semi,
  /// Contrasting glyphs outlined in the colour.
  stroke;

  /// The style after this one, wrapping around.
  TextEntityStyle get next =>
      TextEntityStyle.values[(index + 1) % TextEntityStyle.values.length];

  /// The glyph, frame and outline colours this style makes of [colour].
  ({Color textColor, Color? frameColor, Color? strokeColor}) resolve(
    Color colour,
  ) {
    // Rec.709 luma of the 0–1 sRGB channels as-is, not linearized.
    final lightness = 0.2126 * colour.r + 0.7152 * colour.g + 0.0722 * colour.b;
    final onColour = lightness > 0.99 ? Color(0xFF000000) : Color(0xFFFFFFFF);
    return switch (this) {
      TextEntityStyle.regular => (
        textColor: colour,
        frameColor: null,
        strokeColor: null,
      ),
      TextEntityStyle.filled => (
        textColor: onColour,
        frameColor: colour,
        strokeColor: null,
      ),
      TextEntityStyle.semi => (
        textColor: colour,
        frameColor: lightness > 0.7 ? Color(0xBF000000) : Color(0xBFFFFFFF),
        strokeColor: null,
      ),
      TextEntityStyle.stroke => (
        textColor: onColour,
        frameColor: null,
        strokeColor: colour,
      ),
    };
  }
}

int _nextId = 0;

/// A text overlay in source-image coordinates: [position] is its centre and
/// [width] the box its glyphs wrap in, with [rotation] in radians and [scale]
/// applied about that centre.
class TextEntity {
  /// Creates a text overlay; [id] is generated when absent.
  TextEntity({
    required this.text,
    required this.style,
    required this.align,
    required this.colour,
    required this.fontSize,
    required this.position,
    required this.width,
    this.rotation = 0,
    this.scale = 1,
    String? id,
  }) : id = id ?? 'text-${_nextId++}';

  /// Identifies the overlay across copies.
  final String id;

  /// The string shown.
  String text;
  /// How [colour] is spent.
  TextEntityStyle style;
  /// Alignment of the lines inside [width].
  TextAlign align;
  /// The overlay's colour.
  Color colour;

  /// Normalized 0–1, mapped to source pixels by [displayFontSize].
  double fontSize;

  /// The centre, in source-image pixels.
  Offset position;
  /// Rotation about [position], in radians.
  double rotation;
  /// Scale about [position].
  double scale;
  /// Width of the box the glyphs wrap in, in source-image pixels.
  double width;

  /// [fontSize] in source pixels, against the source image [reference].
  double displayFontSize(Size reference) {
    final minFontSize = math.max(10.0, reference.longestSide * 0.025);
    final maxFontSize = math.max(10.0, reference.longestSide * 0.25);
    return minFontSize + (maxFontSize - minFontSize) * fontSize;
  }

  /// This overlay, same [id], with the given fields replaced.
  TextEntity copyWith({
    String? text,
    TextEntityStyle? style,
    TextAlign? align,
    Color? colour,
    double? fontSize,
    Offset? position,
    double? rotation,
    double? scale,
    double? width,
  }) => TextEntity(
    id: id,
    text: text ?? this.text,
    style: style ?? this.style,
    align: align ?? this.align,
    colour: colour ?? this.colour,
    fontSize: fontSize ?? this.fontSize,
    position: position ?? this.position,
    rotation: rotation ?? this.rotation,
    scale: scale ?? this.scale,
    width: width ?? this.width,
  );
}
