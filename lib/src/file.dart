import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter/services.dart';

/// A single frame extracted from a video file. [pngBytes] is the encoded
/// PNG ready to embed in a thumbnail proto / paint via `Image.memory`;
/// [width] / [height] describe the encoded image, which may be smaller
/// than the source video due to the `maxWidth` constraint at extraction.
class UxVideoThumbnail {
  const UxVideoThumbnail({
    required this.pngBytes,
    required this.width,
    required this.height,
  });

  final Uint8List pngBytes;
  final int width;
  final int height;
}

/// A file the user picked. [path] is on local disk and readable by
/// `dart:io File` — for Android content:// URIs the native side
/// stream-copies the source to the app's cache; for iOS/macOS picks the
/// file is copied to the temp dir so the path is stable after the picker
/// dismisses. Bytes are never marshalled across the platform channel.
class UxPickedFile {
  const UxPickedFile({
    required this.path,
    this.name,
    this.mimeType,
    this.size,
  });

  final String path;
  final String? name;
  final String? mimeType;
  final int? size;
}

class UxFile {
  UxFile._();

  static const _channel = MethodChannel('ux/file');

  /// Present the native share sheet for a file on disk.
  ///
  /// [sourceRect] is the originating widget's rect in Flutter logical
  /// pixels (global coordinates). Required on iPad and macOS (anchor for
  /// the popover); ignored on iPhone and Android. Pass null on iPad/macOS
  /// to center the popover — typical fallback when the originating widget
  /// has been disposed by the time bytes are ready.
  ///
  /// [mimeType] hints `Intent.setType` on Android. Ignored on Apple
  /// platforms (the share sheet infers from the file extension).
  ///
  /// [title] populates the subject hint (Mail subject on iOS/macOS,
  /// chooser title on Android).
  ///
  /// Returns true if the sheet was presented. Returns false if the host
  /// couldn't present it (no activity on Android, no window on macOS).
  static Future<bool> share({
    required String path,
    String? title,
    String? mimeType,
    Rect? sourceRect,
  }) async {
    final result = await _channel.invokeMethod<bool>('share', {
      'path': path,
      if (title != null) 'title': title,
      if (mimeType != null) 'mimeType': mimeType,
      if (sourceRect != null)
        'sourceRect': {
          'x': sourceRect.left,
          'y': sourceRect.top,
          'w': sourceRect.width,
          'h': sourceRect.height,
        },
    });
    return result ?? false;
  }

  /// Open a file on disk with the system's default viewer.
  ///
  /// - iOS: Quick Look preview (`QLPreviewController`) — modal with native
  ///   preview for common types. The built-in toolbar still exposes Share.
  /// - macOS: hands off to the system default app (`NSWorkspace.open`).
  /// - Android: `Intent.ACTION_VIEW` — launches the default viewer app.
  ///
  /// [mimeType] hints the viewer on Android. Ignored on Apple platforms
  /// (the framework infers from the file extension).
  ///
  /// Returns true if the viewer opened. Returns false when no viewer is
  /// available (Android: no app registered for the MIME; macOS: no
  /// associated app).
  static Future<bool> open({
    required String path,
    String? mimeType,
  }) async {
    final result = await _channel.invokeMethod<bool>('open', {
      'path': path,
      if (mimeType != null) 'mimeType': mimeType,
    });
    return result ?? false;
  }

  /// Present the system file picker. Returns the picked file's local-disk
  /// path (and optional metadata), or null if the user cancelled.
  ///
  /// File content is **never** marshalled across the platform channel —
  /// the native side only ships back the path. Use `dart:io` to read the
  /// file: `File(picked.path).openRead()` etc.
  ///
  /// [mimeTypes] filters the picker. Each entry can be a concrete type
  /// (`image/png`), a wildcard (`image/*`), or `*/*`. Null = `[*/*]`.
  /// Note: Apple platforms map MIME → UTType internally; common types
  /// (`image/*`, `video/*`, `application/pdf`) work on all three. For
  /// Apple-specific types prefer concrete MIME like `image/jpeg` over
  /// wildcards.
  static Future<UxPickedFile?> pick({
    List<String>? mimeTypes,
  }) async {
    final result = await _channel.invokeMapMethod<String, Object?>('pick', {
      if (mimeTypes != null) 'mimeTypes': mimeTypes,
    });
    if (result == null) return null;
    final path = result['path'] as String?;
    if (path == null) return null;
    return UxPickedFile(
      path: path,
      name: result['name'] as String?,
      mimeType: result['mimeType'] as String?,
      size: (result['size'] as num?)?.toInt(),
    );
  }

  /// Extract a single frame from the video at [path]. Returns null if the
  /// platform's media decoder couldn't open the file (unsupported codec /
  /// corrupt / not actually a video).
  ///
  /// [atMs] picks the frame timestamp in milliseconds (default 0 = first
  /// available keyframe). [maxWidth] caps the output's longer edge while
  /// preserving aspect ratio.
  static Future<UxVideoThumbnail?> videoThumbnail({
    required String path,
    int atMs = 0,
    int maxWidth = 320,
  }) async {
    final result = await _channel.invokeMapMethod<String, Object?>(
      'videoThumbnail',
      <String, Object?>{
        'path': path,
        'atMs': atMs,
        'maxWidth': maxWidth,
      },
    );
    if (result == null) return null;
    final bytes = result['png'] as Uint8List?;
    final width = (result['width'] as num?)?.toInt();
    final height = (result['height'] as num?)?.toInt();
    if (bytes == null || width == null || height == null) return null;
    return UxVideoThumbnail(pngBytes: bytes, width: width, height: height);
  }
}
