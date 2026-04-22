import 'dart:ui' show Rect;

import 'package:flutter/services.dart';

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
}
