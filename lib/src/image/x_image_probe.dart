import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// What [XImageProbe.thumbnail] reports about one image file.
class XImageThumbnail {
  /// Creates a probe result. Built by [XImageProbe.thumbnail].
  const XImageThumbnail({
    required this.sourceWidth,
    required this.sourceHeight,
    required this.pngBytes,
    required this.width,
    required this.height,
  });

  /// Display dimensions of the *source* — EXIF orientation already applied,
  /// so a portrait photo reports portrait.
  final int sourceWidth;

  /// Display height of the source, EXIF orientation applied.
  final int sourceHeight;

  /// The downscaled PNG, upright.
  final Uint8List pngBytes;

  /// Dimensions of [pngBytes].
  final int width;

  /// Dimensions of [pngBytes].
  final int height;
}

/// Dimensions and a downscaled PNG of an image file, in one native
/// round-trip that **never decodes the image at full resolution**.
///
/// Flutter's own route — `instantiateImageCodec` over the file's bytes — costs
/// 4 bytes per source pixel even when the caller only wants a 200px thumbnail
/// or the intrinsic size: ~190 MB for a 48-megapixel photo. That is several
/// times the memory an **app extension** is allowed, so a share surface that
/// describes photos it never displays at full size cannot use it.
///
/// Apple reads the header and asks ImageIO for a thumbnail
/// (`CGImageSourceCreateThumbnailAtIndex`); Android measures with
/// `inJustDecodeBounds` and decodes subsampled (`inSampleSize`); Windows reads
/// the header and decodes through WIC's `IWICBitmapScaler`, with whichever
/// codecs Windows has installed, HEIF among them where its extension is. All
/// are bounded by the *output* size, not the source.
class XImageProbe {
  XImageProbe._();

  static const _channel = MethodChannel('ux/image_probe');

  /// Whether this platform has the native probe. Elsewhere the caller keeps
  /// its own decode path.
  static bool get supported =>
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isAndroid ||
      Platform.isWindows;

  /// Measures [path] and renders it down so its longest edge is at most
  /// [maxLongest]. An image already within that bound comes back at its own
  /// size rather than upscaled.
  ///
  /// Null when the file is not a decodable image.
  static Future<XImageThumbnail?> thumbnail({
    required String path,
    required int maxLongest,
  }) async {
    if (!supported) return null;
    final result = await _channel.invokeMapMethod<String, Object?>(
      'thumbnail',
      {'path': path, 'maxLongest': maxLongest},
    );
    if (result == null) return null;
    final sourceWidth = (result['sourceWidth'] as num?)?.toInt();
    final sourceHeight = (result['sourceHeight'] as num?)?.toInt();
    final width = (result['width'] as num?)?.toInt();
    final height = (result['height'] as num?)?.toInt();
    final png = result['png'] as Uint8List?;
    if (sourceWidth == null ||
        sourceHeight == null ||
        width == null ||
        height == null ||
        png == null) {
      return null;
    }
    return XImageThumbnail(
      sourceWidth: sourceWidth,
      sourceHeight: sourceHeight,
      pngBytes: png,
      width: width,
      height: height,
    );
  }

  /// Display dimensions alone, read from the header — no pixels decoded.
  /// Null when the file is not a decodable image.
  static Future<({int width, int height})?> size(String path) async {
    if (!supported) return null;
    final result = await _channel.invokeMapMethod<String, Object?>('size', {
      'path': path,
    });
    final width = (result?['width'] as num?)?.toInt();
    final height = (result?['height'] as num?)?.toInt();
    if (width == null || height == null) return null;
    return (width: width, height: height);
  }
}
