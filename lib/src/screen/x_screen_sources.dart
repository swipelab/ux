import 'dart:typed_data';

import 'package:ux/src/screen/x_screen_sources_channel.dart'
    show MethodChannelXScreenSourcesBackend;

/// What a [XScreenSource] captures.
enum XScreenSourceKind {
  /// A whole display.
  display,

  /// A single application window.
  window,
}

/// One capturable surface — a display or a window — with the preview the
/// picker draws for it.
final class XScreenSource {
  /// Creates a source description.
  const XScreenSource({
    required this.id,
    required this.kind,
    required this.title,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.thumbnailPng,
    this.applicationName,
  });

  /// Identifier of the surface, in the same namespace the capture stack
  /// enumerates: selection hands this value straight back to it.
  final String id;

  /// Whether [id] names a display or a window.
  final XScreenSourceKind kind;

  /// Label to show: the display's name, or the window's title.
  final String title;

  /// Application owning a window source, when the platform names one.
  final String? applicationName;

  /// Width of the surface itself in pixels — not of [thumbnailPng].
  final int sourceWidth;

  /// Height of the surface itself in pixels — not of [thumbnailPng].
  final int sourceHeight;

  /// PNG preview of the surface, or `null` when this one source failed to
  /// render while others succeeded.
  final Uint8List? thumbnailPng;
}

/// Thrown by [XScreenSourcesBackend] when a call cannot be served.
///
/// [code] is one of `unsupported`, `permission_denied`, `enumeration_failed`,
/// `thumbnail_failed`, or the Dart-owned `invalid_response` — a native reply
/// that does not match the wire contract, whose [message] names the offending
/// field.
class XScreenSourcesException implements Exception {
  /// Creates an exception with a wire [code] and an optional [message].
  const XScreenSourcesException(this.code, [this.message]);

  /// Machine-readable failure kind.
  final String code;

  /// Platform-supplied detail, when there is one.
  final String? message;

  @override
  String toString() => 'XScreenSourcesException($code, $message)';
}

/// The displays and windows a screen-share picker can offer, each with a
/// rendered thumbnail, taken as one snapshot.
///
/// ```dart
/// final backend = XScreenSourcesBackend.instance;
/// if (await backend.hasPermission()) {
///   final sources = await backend.list(
///     allowedDisplayIds: displayIds,
///     allowedWindowIds: windowIds,
///   );
/// }
/// ```
///
/// The caller passes the ids it is willing to capture and presents exactly
/// what comes back. [list] never prompts — permission is [hasPermission] and
/// [requestPermission], which the caller drives before it opens a picker.
abstract interface class XScreenSourcesBackend {
  /// The process-wide backend. Swap to inject a fake before any picker code
  /// runs.
  static XScreenSourcesBackend instance = MethodChannelXScreenSourcesBackend();

  /// Whether this platform family has a native picker. Elsewhere every
  /// method throws [XScreenSourcesException] with code `unsupported`, before
  /// it looks at its arguments.
  bool get supported;

  /// Whether this host can serve a snapshot — the OS version as well as the
  /// platform family.
  Future<bool> available();

  /// Whether screen recording is granted. Never prompts.
  Future<bool> hasPermission();

  /// Asks for screen-recording access, returning the state the call leaves
  /// behind.
  Future<bool> requestPermission();

  /// The allowed sources present right now, each with a [thumbnailWidth] ×
  /// [thumbnailHeight] aspect-fit PNG.
  ///
  /// A source whose thumbnail fails to render comes back with a null
  /// [XScreenSource.thumbnailPng]; `thumbnail_failed` is thrown only when no
  /// requested source renders at all.
  ///
  /// Both dimensions must be between 1 and 4096, or this throws
  /// [ArgumentError] without reaching the platform.
  Future<List<XScreenSource>> list({
    required Set<String> allowedDisplayIds,
    required Set<String> allowedWindowIds,
    int thumbnailWidth = 320,
    int thumbnailHeight = 180,
  });
}
