import 'package:ux/src/screen/x_screen_sources.dart';

/// In-memory backend for screen-picker tests. Swap in via
/// `XScreenSourcesBackend.instance = FakeXScreenSourcesBackend(...)` before
/// any picker code runs; restore with `XScreenSourcesBackend.instance =
/// MethodChannelXScreenSourcesBackend()` in `tearDown`.
///
/// Records every call and returns scripted answers: mutate [sources],
/// [permission] and the `…Error` fields between assertions to drive the
/// picker's success, denial and failure paths.
class FakeXScreenSourcesBackend implements XScreenSourcesBackend {
  /// Creates a fake that starts out picker-driven, supported, available, and
  /// not yet granted.
  FakeXScreenSourcesBackend({
    List<XScreenSource> sources = const [],
    this.captureMode = XScreenCaptureMode.pickerDriven,
    this.supported = true,
    this.availableResult = true,
    this.permission = false,
    this.requestPermissionResult = true,
  }) : sources = List.of(sources);

  /// Every [list] call, in order, with the arguments it was given.
  final List<
      ({
        Set<String> allowedDisplayIds,
        Set<String> allowedWindowIds,
        int thumbnailWidth,
        int thumbnailHeight,
      })> listCalls = [];

  /// Number of [available] calls.
  int availableCalls = 0;

  /// Number of [hasPermission] calls.
  int hasPermissionCalls = 0;

  /// Number of [requestPermission] calls.
  int requestPermissionCalls = 0;

  /// Snapshot returned by [list].
  List<XScreenSource> sources;

  @override
  XScreenCaptureMode? captureMode;

  @override
  bool supported;

  /// Result of [available].
  bool availableResult;

  /// Result of [hasPermission], and what [requestPermission] grants.
  bool permission;

  /// Result of [requestPermission]; a `true` also sets [permission].
  bool requestPermissionResult;

  /// If non-null, thrown by [list] instead of returning [sources].
  XScreenSourcesException? listError;

  /// If non-null, thrown by [available].
  XScreenSourcesException? availableError;

  /// If non-null, thrown by [hasPermission].
  XScreenSourcesException? hasPermissionError;

  /// If non-null, thrown by [requestPermission].
  XScreenSourcesException? requestPermissionError;

  @override
  Future<bool> available() async {
    _requireSupported();
    availableCalls += 1;
    final err = availableError;
    if (err != null) throw err;
    return availableResult;
  }

  @override
  Future<bool> hasPermission() async {
    _requireSupported();
    hasPermissionCalls += 1;
    final err = hasPermissionError;
    if (err != null) throw err;
    return permission;
  }

  @override
  Future<bool> requestPermission() async {
    _requireSupported();
    requestPermissionCalls += 1;
    final err = requestPermissionError;
    if (err != null) throw err;
    if (requestPermissionResult) permission = true;
    return requestPermissionResult;
  }

  @override
  Future<List<XScreenSource>> list({
    required Set<String> allowedDisplayIds,
    required Set<String> allowedWindowIds,
    int thumbnailWidth = 320,
    int thumbnailHeight = 180,
  }) async {
    _requireSupported();
    listCalls.add((
      allowedDisplayIds: allowedDisplayIds,
      allowedWindowIds: allowedWindowIds,
      thumbnailWidth: thumbnailWidth,
      thumbnailHeight: thumbnailHeight,
    ));
    final err = listError;
    if (err != null) throw err;
    return List.unmodifiable(sources);
  }

  void _requireSupported() {
    if (supported) return;
    throw const XScreenSourcesException('unsupported', 'fake');
  }
}
