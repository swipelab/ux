import 'package:flutter/services.dart';

/// OS clipboard access for shapes Flutter's [Clipboard] doesn't cover.
/// Right now this is image bytes — the system text path is already
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
}
