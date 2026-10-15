import 'package:flutter/foundation.dart';

/// Baked crop/rotate/flip geometry for a video export, snapshotted from the
/// entry's `CropImageLayer` at send time (`CropImageLayer.exportMatrix` +
/// `exportSize`, already clamped to the chosen quality tier). [transform]
/// is a row-major 3×3 affine mapping **source pixel** → **output pixel**
/// coordinates (`[a,b,tx, d,e,ty, 0,0,1]`); the output canvas is
/// [outWidth]×[outHeight]. Handed verbatim to `XVideoExporter` so the
/// exported frames match the on-screen crop.
@immutable
class VideoCropGeometry {
  /// Binds the affine to its output canvas.
  const VideoCropGeometry({
    required this.transform,
    required this.outWidth,
    required this.outHeight,
  });

  /// Row-major 3×3 source-px → output-px affine (`[a,b,tx, d,e,ty, 0,0,1]`).
  final List<double> transform;

  /// Width of the output canvas in pixels.
  final int outWidth;

  /// Height of the output canvas in pixels.
  final int outHeight;

  /// [transform] as the column-major 4×4 storage Flutter's `Transform`
  /// widget and `Canvas.transform` consume — the live cropped preview
  /// and the baked poster thumb apply the identical mapping through it.
  Float64List get transformColumnMajor4x4 => Float64List.fromList(<double>[
    transform[0], transform[3], 0, 0, // column 0
    transform[1], transform[4], 0, 0, // column 1
    0, 0, 1, 0, // column 2
    transform[2], transform[5], 0, 1, // column 3 (translation)
  ]);

  @override
  bool operator ==(Object other) =>
      other is VideoCropGeometry &&
      other.outWidth == outWidth &&
      other.outHeight == outHeight &&
      listEquals(other.transform, transform);

  @override
  int get hashCode =>
      Object.hash(outWidth, outHeight, Object.hashAll(transform));
}

/// Rasterised paint strokes for a video export — a transparent PNG at
/// the upright source's pixel dimensions (the strokes stay vector on the
/// entry's `DrawImageLayer`; this is the apply-time bake the natives
/// composite over every frame before the crop affine).
@immutable
class VideoDrawOverlay {
  /// Binds the PNG at [path] to its pixel size.
  const VideoDrawOverlay({
    required this.path,
    required this.width,
    required this.height,
  });

  /// Absolute path of the strokes-only PNG.
  final String path;

  /// Source-space pixel width of the PNG, equal to the poster's.
  final int width;

  /// Source-space pixel height of the PNG, equal to the poster's.
  final int height;

  @override
  bool operator ==(Object other) =>
      other is VideoDrawOverlay &&
      other.path == path &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(path, width, height);
}

/// Per-entry video edit state: the trim range and mute, the crop geometry
/// and the rasterised paint overlay. Owned by `ComposeEntry` and carried by
/// `ComposeResult` to the sender, which bakes it through `XVideoExporter`.
/// Null bounds mean "keep the source edge"; a values object with nothing
/// set is equivalent to no edits.
@immutable
class VideoEditValues {
  /// No edits unless a field is set.
  const VideoEditValues({
    this.trimStart,
    this.trimEnd,
    this.muted = false,
    this.crop,
    this.overlay,
  });

  /// Trim range start, null = source start.
  final Duration? trimStart;

  /// Trim range end, null = source end.
  final Duration? trimEnd;

  /// Send without the audio track.
  final bool muted;

  /// Baked crop/rotate/flip geometry, or null for no geometric edit.
  /// When set, the export re-encodes (vs. the trim/mute passthrough).
  final VideoCropGeometry? crop;

  /// Rasterised paint strokes, or null when nothing is drawn. Always
  /// rides the re-encode path (composited before [crop]'s affine).
  final VideoDrawOverlay? overlay;

  /// Whether sending must run the export at all.
  bool get hasEdits =>
      trimStart != null ||
      trimEnd != null ||
      muted ||
      crop != null ||
      overlay != null;

  /// These values with the given fields replaced.
  VideoEditValues copyWith({
    Duration? trimStart,
    Duration? trimEnd,
    bool? muted,
    VideoCropGeometry? crop,
    VideoDrawOverlay? overlay,
    bool clearTrimStart = false,
    bool clearTrimEnd = false,
    bool clearCrop = false,
    bool clearOverlay = false,
  }) {
    return VideoEditValues(
      trimStart: clearTrimStart ? null : (trimStart ?? this.trimStart),
      trimEnd: clearTrimEnd ? null : (trimEnd ?? this.trimEnd),
      muted: muted ?? this.muted,
      crop: clearCrop ? null : (crop ?? this.crop),
      overlay: clearOverlay ? null : (overlay ?? this.overlay),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is VideoEditValues &&
      other.trimStart == trimStart &&
      other.trimEnd == trimEnd &&
      other.muted == muted &&
      other.crop == crop &&
      other.overlay == overlay;

  @override
  int get hashCode => Object.hash(trimStart, trimEnd, muted, crop, overlay);
}
