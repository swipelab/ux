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

/// How a platform decides what a screen share captures.
enum XScreenCaptureMode {
  /// The app enumerates the capturable surfaces, draws them, and hands the
  /// chosen id back — [XScreenSourcesBackend.list] and a picker.
  pickerDriven,

  /// The system's own consent surface both asks and chooses; nothing is
  /// enumerated, [XScreenSourcesBackend.list] has no role, and a capture runs
  /// inside the [XScreenSourcesBackend.startShare] bracket.
  consentDriven,
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
/// `thumbnail_failed`, `service_start_failed`, or the Dart-owned
/// `invalid_response` — a native reply that does not match the wire contract,
/// whose [message] names the offending field.
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

/// What a screen share needs from the platform, which [captureMode] splits in
/// two: the displays and windows a picker can offer, each with a rendered
/// thumbnail, taken as one snapshot — or the bracket a consent-driven capture
/// runs inside.
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

  /// How this platform family shares a screen, or `null` where it shares none
  /// at all. Independent of [supported]: a family names its mode even where no
  /// capture ships for it.
  XScreenCaptureMode? get captureMode;

  /// Whether this platform family serves these calls. Elsewhere every method
  /// throws [XScreenSourcesException] with code `unsupported`, before it looks
  /// at its arguments — and so does every call the family's [captureMode] has
  /// no role for: [list] and the permission pair off
  /// [XScreenCaptureMode.pickerDriven], [startShare] and [stopShare] off
  /// [XScreenCaptureMode.consentDriven].
  bool get supported;

  /// Whether this host can serve its [captureMode] — the platform family and
  /// the OS version, plus whatever else the platform makes a capture depend
  /// on: on iOS this is ReplayKit's own answer, false while the app is not in
  /// front, a mirrored display is attached, or another recorder holds the
  /// screen.
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

  /// Takes the hold a consent-driven capture runs inside, showing an ongoing
  /// notification titled [notificationTitle] with [notificationText] under it.
  ///
  /// It belongs between the system's consent and the capture start: the hold
  /// is granted only once consent is, and the capture only succeeds while the
  /// hold is up. A platform that asks for no hold answers here anyway, with
  /// whether it would serve a capture right now, and has no role for the
  /// notification arguments.
  ///
  /// Throws [XScreenSourcesException] with `permission_denied` when the
  /// platform refuses the hold for want of consent, and `service_start_failed`
  /// when it refuses for anything else or when a later [startShare] or a
  /// [stopShare] settles this one before the hold is up. An empty
  /// [notificationTitle] throws [ArgumentError] without reaching the platform.
  Future<void> startShare({
    required String notificationTitle,
    String? notificationText,
  });

  /// Drops the hold [startShare] took. Dropping one nobody holds succeeds.
  Future<void> stopShare();
}
