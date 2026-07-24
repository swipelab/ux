import 'package:flutter/services.dart';

/// A file reference read from the system clipboard (e.g. a Finder
/// "Copy"). [bookmark] is a macOS security-scoped bookmark so a
/// sandboxed reader can re-acquire access after the transient
/// pasteboard grant lapses; null where not applicable.
class XClipboardFile {
  const XClipboardFile({
    required this.path,
    required this.name,
    this.bookmark,
  });

  final String path;
  final String name;
  final Uint8List? bookmark;
}

/// OS clipboard access for shapes Flutter's [Clipboard] doesn't cover.
/// Image bytes and copied files — the system text path is already
/// handled by the SDK's `Clipboard.getData(Clipboard.kTextPlain)`.
class XClipboard {
  XClipboard._();

  static const _channel = MethodChannel('ux/clipboard');

  /// Returns the image currently on the system clipboard as raw bytes
  /// (PNG on iOS / macOS / Android), or `null` if no image is available.
  ///
  /// On macOS the call also handles TIFF clipboards by transcoding to
  /// PNG; Android resolves `content://` URIs through ContentResolver and
  /// returns the underlying image bytes verbatim. Never throws — channel
  /// failures resolve to `null`.
  static Future<Uint8List?> readImage() async {
    try {
      final bytes = await _channel.invokeMethod<Uint8List>('readImage');
      return bytes;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Whether the clipboard currently holds media this class can paste —
  /// an image on any platform, copied files on macOS. Type-level check
  /// only: it never reads clip contents, so it triggers neither iOS's
  /// paste-permission prompt nor Android 12+'s paste toast. Drives paste
  /// affordances (e.g. showing a Paste menu item for an image-only
  /// clipboard, which the text-oriented `Clipboard.hasStrings` misses).
  static Future<bool> hasMedia() async {
    try {
      return await _channel.invokeMethod<bool>('hasMedia') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Files currently on the system clipboard (a Finder / file-manager
  /// "Copy"). macOS only for now — other platforms (and channel
  /// failures) resolve to an empty list. Check this BEFORE [readImage]:
  /// a copied file may also expose a thumbnail image on the pasteboard,
  /// and the file is the user's intent.
  static Future<List<XClipboardFile>> readFiles() async {
    try {
      final raw = await _channel.invokeListMethod<Object?>('readFiles');
      if (raw == null) return const [];
      return [
        for (final entry in raw)
          if (entry is Map)
            XClipboardFile(
              path: entry['path']! as String,
              name: entry['name']! as String,
              bookmark: entry['bookmark'] as Uint8List?,
            ),
      ];
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }
}
