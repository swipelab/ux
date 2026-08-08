import 'package:flutter/services.dart';

/// What [XVideoProbe.probe] reports about one video file.
class XVideoProbeResult {
  const XVideoProbeResult({
    required this.width,
    required this.height,
    required this.durationMs,
    this.posterPng,
  });

  /// Display dimensions — the track's natural size with its preferred
  /// transform applied, so a portrait recording reports portrait.
  final int width;
  final int height;

  final int durationMs;

  /// PNG of the requested frame, or null when the decode failed (an
  /// unsupported codec still yields dimensions and duration).
  final Uint8List? posterPng;
}

/// Dimensions, duration and a poster frame in one native round-trip.
///
/// Backed by AVFoundation (Apple) / `MediaMetadataRetriever` (Android) alone —
/// no player, no texture registry — which is what makes it usable inside an
/// **app extension**, where the `XVideoPlayer` route is not available, and
/// cheap enough for a share surface that describes files it never plays.
class XVideoProbe {
  XVideoProbe._();

  static const _channel = MethodChannel('ux/video_probe');

  /// Probes [path]. Null when the file yields no video track at all. [maxWidth]
  /// caps the poster's width (aspect preserved); null asks for the frame at
  /// native resolution.
  static Future<XVideoProbeResult?> probe({
    required String path,
    int atMs = 0,
    int? maxWidth = 320,
  }) async {
    final result = await _channel.invokeMapMethod<String, Object?>('probe', {
      'path': path,
      'atMs': atMs,
      'maxWidth': maxWidth,
    });
    if (result == null) return null;
    final width = (result['width'] as num?)?.toInt();
    final height = (result['height'] as num?)?.toInt();
    final durationMs = (result['durationMs'] as num?)?.toInt();
    if (width == null || height == null || durationMs == null) return null;
    return XVideoProbeResult(
      width: width,
      height: height,
      durationMs: durationMs,
      posterPng: result['png'] as Uint8List?,
    );
  }
}
