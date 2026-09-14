import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// A single frame extracted from a video file. [pngBytes] is the encoded
/// PNG ready to embed in a thumbnail proto / paint via `Image.memory`;
/// [width] / [height] describe the encoded image, which may be smaller
/// than the source video due to the `maxWidth` constraint at extraction.
class XVideoThumbnail {
  /// Binds the encoded frame to the size it decodes at.
  const XVideoThumbnail({
    required this.pngBytes,
    required this.width,
    required this.height,
  });

  /// Encoded PNG of the frame.
  final Uint8List pngBytes;

  /// Pixel width of the encoded image.
  final int width;

  /// Pixel height of the encoded image.
  final int height;
}

/// A handle to a file on local disk. Minimal — [path] is the only
/// guaranteed field. Returned from anything in `package:ux` that produces
/// a file (camera capture today; future writers).
class XFile {
  /// Binds the handle to a path on local disk.
  const XFile(this.path);

  /// Absolute path on local disk. Readable through `dart:io File`. Lifetime
  /// is producer-defined — camera capture writes to a temp dir, the
  /// picker grant is held by the OS while the session is alive, etc.
  final String path;
}

/// A file the user picked. [path] is on local disk and readable by
/// `dart:io File` while the picker session's grant is active.
///
/// On macOS / iOS the picker returns the user's original location (no
/// temp-dir copy); access across cold restarts is preserved by storing
/// [bookmark] and re-acquiring scope via [XFiles.withScopedAccess] /
/// [XFiles.open] / [XFiles.showInFolder]. On Android the native side
/// stream-copies a `content://` source into the app cache (since
/// `dart:io` can't open content URIs); [bookmark] holds the source URI
/// as UTF-8 bytes for symmetry but isn't required for reads.
class XPickedFile {
  /// Binds the readable path to whatever metadata the picker supplied.
  const XPickedFile({
    required this.path,
    this.name,
    this.mimeType,
    this.size,
    this.bookmark,
    this.isTemporaryCopy = false,
  });

  /// Absolute path on local disk, readable while the grant is active.
  final String path;

  /// Display name the picker reported, where it reported one.
  final String? name;

  /// Media type the picker reported, where it reported one.
  final String? mimeType;

  /// Size in bytes the picker reported, where it reported one.
  final int? size;

  /// macOS / iOS scoped bookmark, or Android URI bytes. Persist alongside
  /// [path] so future opens can re-acquire access. Null on platforms that
  /// don't need it (or when the platform supplied no bookmark).
  final Uint8List? bookmark;

  /// True when [path] is an app-owned temp copy the platform made for us
  /// rather than a durable user-chosen location: the Android SAF picker
  /// stream-copies a `content://` source into the app cache (since `dart:io`
  /// can't open content URIs). Callers should treat such a source as
  /// ephemeral — e.g. promote its bytes into a managed cache after upload
  /// instead of referencing the temp in place (it is cleared by the OS and
  /// isn't externally openable on Android). False for macOS/iOS/desktop picks,
  /// which return the user's real file.
  final bool isTemporaryCopy;
}

/// Outcome of [XFiles.saveCopy]. [denied] means the user refused the
/// storage permission (Android API <29 only) — the save can't proceed.
/// [cancelled] means the user dismissed the export picker (iOS). Hard
/// failures (unreadable source, write error) throw a `PlatformException`.
enum XFileSaveStatus {
  /// The copy reached the destination.
  saved,

  /// The user dismissed the export picker.
  cancelled,

  /// Storage permission was refused.
  denied,
}

/// Static facade over the platform's file services — sharing, picking,
/// saving, and scoped access.
class XFiles {
  XFiles._();

  static const _channel = MethodChannel('ux/file');

  /// Run [body] with scoped access to a file. On macOS / iOS, when
  /// [bookmark] is non-null, the plugin resolves the bookmark into a
  /// security-scoped URL, starts access, hands the resolved path to
  /// [body], and stops access in `finally`. On all other platforms (and
  /// when [bookmark] is null) [body] is invoked with [path] directly.
  ///
  /// The plugin maintains a per-path begin counter so nested calls are
  /// safe. Access is always released in `finally`, including on errors.
  static Future<T> withScopedAccess<T>(
    String path,
    Uint8List? bookmark,
    Future<T> Function(String path) body,
  ) async {
    if (bookmark == null || !(Platform.isMacOS || Platform.isIOS)) {
      return body(path);
    }
    final result = await _channel.invokeMapMethod<String, Object?>(
      'beginScopedAccess',
      {'bookmark': bookmark},
    );
    final resolvedPath = result?['path'] as String? ?? path;
    try {
      return await body(resolvedPath);
    } finally {
      await _channel
          .invokeMethod<void>('endScopedAccess', {'path': resolvedPath});
    }
  }

  /// Whether [share] has a native sheet on this platform — iOS /
  /// Android / macOS. Gate share affordances so they don't appear
  /// where the channel has no handler.
  static bool get supportsShare =>
      Platform.isIOS || Platform.isAndroid || Platform.isMacOS;

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
      'title': ?title,
      'mimeType': ?mimeType,
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

  /// Whether [saveCopy] has a native implementation — iOS / Android /
  /// macOS.
  static bool get supportsSaveCopy =>
      Platform.isIOS || Platform.isAndroid || Platform.isMacOS;

  /// Save a user-visible copy of the file at [path].
  ///
  /// - iOS: presents the system export picker ("Save to Files"); the
  ///   user chooses the destination. Dismissal returns [XFileSaveStatus.cancelled].
  /// - Android: inserts into the Downloads collection (API 29+, no
  ///   permission needed) or copies into the public Downloads folder
  ///   after a `WRITE_EXTERNAL_STORAGE` grant (API <29 —
  ///   [XFileSaveStatus.denied] when refused).
  /// - macOS: presents an `NSSavePanel` and copies to the chosen
  ///   destination. Dismissal returns [XFileSaveStatus.cancelled].
  ///
  /// [mimeType] hints the `MediaStore` row on Android; ignored on Apple
  /// platforms.
  static Future<XFileSaveStatus> saveCopy({
    required String path,
    String? mimeType,
  }) async {
    final s = await _channel.invokeMethod<String>('saveCopy', {
      'path': path,
      'mimeType': ?mimeType,
    });
    return switch (s) {
      'saved' => XFileSaveStatus.saved,
      'denied' => XFileSaveStatus.denied,
      _ => XFileSaveStatus.cancelled,
    };
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
    Uint8List? bookmark,
  }) async {
    final result = await _channel.invokeMethod<bool>('open', {
      'path': path,
      'mimeType': ?mimeType,
      'bookmark': ?bookmark,
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
  static Future<XPickedFile?> pick({
    List<String>? mimeTypes,
  }) async {
    final result = await _channel.invokeMapMethod<String, Object?>('pick', {
      'mimeTypes': ?mimeTypes,
    });
    if (result == null) return null;
    final path = result['path'] as String?;
    if (path == null) return null;
    return XPickedFile(
      path: path,
      name: result['name'] as String?,
      mimeType: result['mimeType'] as String?,
      size: (result['size'] as num?)?.toInt(),
      bookmark: result['bookmark'] as Uint8List?,
      isTemporaryCopy: result['isTemporaryCopy'] as bool? ?? false,
    );
  }

  /// Reveal a file on disk in the system's file browser.
  ///
  /// - macOS: opens (or surfaces) a Finder window with the file selected
  ///   (`NSWorkspace.activateFileViewerSelecting`).
  /// - All other platforms: no-op, returns false.
  ///
  /// Returns true on macOS when Finder accepted the request.
  static Future<bool> showInFolder({
    required String path,
    Uint8List? bookmark,
  }) async {
    if (!Platform.isMacOS) return false;
    final result = await _channel.invokeMethod<bool>('showInFolder', {
      'path': path,
      'bookmark': ?bookmark,
    });
    return result ?? false;
  }

  /// Whether the host platform supports [showInFolder]. Currently macOS
  /// only — call sites can use this to gate UI affordances ("Show in
  /// Finder" buttons) so they don't appear where they're inert.
  static bool get supportsShowInFolder => Platform.isMacOS;

  /// Extract a single frame from the video at [path]. Returns null if the
  /// platform's media decoder couldn't open the file (unsupported codec /
  /// corrupt / not actually a video).
  ///
  /// [atMs] picks the frame timestamp in milliseconds (default 0 = first
  /// available keyframe). [maxWidth] caps the output's longer edge while
  /// preserving aspect ratio; null returns the frame at its native
  /// resolution (the video-crop poster path, where the frame is the
  /// coordinate space of an export geometry and must not be rescaled).
  ///
  /// **Baked variant.** With [transform] (`XVideoExportRequest`'s
  /// row-major 3×3 upright-source-px → output-px affine, with
  /// [outWidth]/[outHeight] as the output canvas) the native side bakes
  /// the frame into the caller's export geometry: the optional
  /// [overlayPath] (transparent PNG at upright source dims) is
  /// composited BEFORE the affine, the affine output is scaled so its
  /// longest edge fits [maxLongest], and the finished PNG comes back —
  /// pixel-matched to `XVideoExporter`'s frames. The whole bake runs in
  /// the native software rasteriser; callers must not re-rasterise the
  /// frame through `Picture.toImage`, which silently produces
  /// blank/black frames in some device states. [maxWidth] is ignored on
  /// the baked path.
  static Future<XVideoThumbnail?> videoThumbnail({
    required String path,
    int atMs = 0,
    int? maxWidth = 320,
    List<double>? transform,
    int? outWidth,
    int? outHeight,
    String? overlayPath,
    int? maxLongest,
  }) async {
    assert((transform == null) == (outWidth == null) &&
        (outWidth == null) == (outHeight == null));
    assert(transform == null || transform.length == 9);
    assert(overlayPath == null || transform != null);
    final result = await _channel.invokeMapMethod<String, Object?>(
      'videoThumbnail',
      <String, Object?>{
        'path': path,
        'atMs': atMs,
        'maxWidth': maxWidth,
        'transform': ?transform,
        'outWidth': ?outWidth,
        'outHeight': ?outHeight,
        'overlayPath': ?overlayPath,
        'maxLongest': ?maxLongest,
      },
    );
    if (result == null) return null;
    final bytes = result['png'] as Uint8List?;
    final width = (result['width'] as num?)?.toInt();
    final height = (result['height'] as num?)?.toInt();
    if (bytes == null || width == null || height == null) return null;
    return XVideoThumbnail(pngBytes: bytes, width: width, height: height);
  }

  /// Extract several frames in one native round-trip — the strip of
  /// thumbnails behind a video trim scrubber. Frames come back in
  /// [timestampsMs] order; entries whose decode failed are null.
  /// Timestamps land on the nearest keyframe (fast path on both
  /// platforms), so neighbouring entries may repeat on sparse-keyframe
  /// sources.
  static Future<List<XVideoThumbnail?>> videoThumbnails({
    required String path,
    required List<int> timestampsMs,
    int maxWidth = 128,
  }) async {
    final result = await _channel.invokeListMethod<Object?>(
      'videoThumbnails',
      <String, Object?>{
        'path': path,
        'timestampsMs': timestampsMs,
        'maxWidth': maxWidth,
      },
    );
    if (result == null) {
      return List<XVideoThumbnail?>.filled(timestampsMs.length, null);
    }
    return result.map((entry) {
      if (entry is! Map) return null;
      final bytes = entry['png'] as Uint8List?;
      final width = (entry['width'] as num?)?.toInt();
      final height = (entry['height'] as num?)?.toInt();
      if (bytes == null || width == null || height == null) return null;
      return XVideoThumbnail(pngBytes: bytes, width: width, height: height);
    }).toList();
  }
}
