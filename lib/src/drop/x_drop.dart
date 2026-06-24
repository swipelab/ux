import 'dart:async';

import 'package:flutter/foundation.dart'
    show
        ValueChanged,
        ValueListenable,
        defaultTargetPlatform,
        TargetPlatform,
        visibleForTesting;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../log.dart' show Log;

final _log = Log.tag('drop');

/// A file delivered by an OS drag-and-drop.
///
/// [path] is readable through `dart:io File` while the drag grant is alive.
/// [bookmark] is a macOS security-scoped bookmark with the same shape as
/// `XPickedFile.bookmark`, so a sandboxed read can re-acquire access via
/// `XFiles.withScopedAccess`. [name] is the basename. [mimeType] is currently
/// always null on macOS — classify by extension.
class XDropFile {
  /// Creates a descriptor for one dropped file.
  const XDropFile({
    required this.path,
    required this.name,
    this.mimeType,
    this.bookmark,
    this.isTemporaryCopy = false,
    this.isDirectory = false,
  });

  /// Absolute path on local disk, readable while the drag grant is alive.
  final String path;

  /// Basename of [path].
  final String name;

  /// MIME type if the platform supplied one; currently always null on macOS.
  final String? mimeType;

  /// macOS security-scoped bookmark for a sandboxed read, or null.
  final Uint8List? bookmark;

  /// True when [path] is an app-owned temp copy the OS wrote for a *promised*
  /// file — a drag from a source that vends `NSFilePromiseReceiver` outputs
  /// rather than a concrete file URL (e.g. Photos) — rather than a durable
  /// user-chosen location. Callers should treat such a source as ephemeral:
  /// promote its bytes into a managed cache after upload instead of recording
  /// the temp path in place (it is purged with the OS temp dir). False for
  /// plain file URLs. Mirrors `XPickedFile.isTemporaryCopy`.
  final bool isTemporaryCopy;

  /// True when [path] is a directory — a folder, or a macOS package the Finder
  /// presents as a single file (`.utm`, `.app`, …). A directory can't be
  /// uploaded as one file, so the app zips it before sending rather than
  /// enqueuing a send that would fail (stat'ing the path throws `Is a
  /// directory`).
  final bool isDirectory;

  /// Decodes one item from the native `ux/drop/events` `drop` payload. Returns
  /// null when the item carries no usable [path] (so a malformed item is
  /// skipped rather than yielding a phantom file). Exposed for testing the wire
  /// decode; the channel itself is exercised end-to-end on device.
  @visibleForTesting
  static XDropFile? fromItem(Map<Object?, Object?> item) {
    final path = item['path'];
    if (path is! String || path.isEmpty) return null;
    final name = item['name'];
    return XDropFile(
      path: path,
      name: name is String && name.isNotEmpty ? name : path.split('/').last,
      mimeType: item['mimeType'] as String?,
      bookmark: item['bookmark'] as Uint8List?,
      isTemporaryCopy: item['isTemporaryCopy'] as bool? ?? false,
      isDirectory: item['isDirectory'] as bool? ?? false,
    );
  }
}

/// A running folder-compression job started by [XDrop.startZip].
///
/// Bind a progress UI to [progress] (0..1), `await` [result] for the produced
/// `.zip` (null when cancelled or unsupported; throws on a genuine failure),
/// and call [cancel] to abort. One-shot — start a new job per drop.
class ZipJob {
  const ZipJob._({
    required this.id,
    required this.progress,
    required this.result,
    required this.cancel,
  });

  /// Opaque job id (also the native correlation key).
  final String id;

  /// Determinate compression fraction, 0..1, updated as native reports.
  final ValueListenable<double> progress;

  /// Completes with the produced zip; null if cancelled or on a platform
  /// without native drop support; throws on a genuine zip failure (so the
  /// caller can surface it instead of silently sending nothing).
  final Future<XDropFile?> result;

  /// Request cancellation; [result] then completes with null.
  final VoidCallback cancel;
}

/// Native drag phase. Internal.
enum _Phase { enter, update, exit, drop }

class _RawEvent {
  const _RawEvent(this.phase, this.position, this.files);

  final _Phase phase;

  /// Flutter global logical coords; meaningless (`Offset.zero`) for [exit].
  final Offset position;

  /// Non-empty only for [drop].
  final List<XDropFile> files;
}

typedef _RawListener = void Function(_RawEvent event);

/// Singleton bridge to the native `ux/drop/events` stream. Fans raw drag
/// events out to the registered [XDropRegion]s, each of which hit-tests its
/// own bounds.
///
/// Subscribes lazily on the first region (zero native overhead until a drop
/// region is mounted — so never on mobile, where no native handler exists) and
/// then *intentionally never cancels* the subscription: cancelling when the
/// listener set empties would lose a drop in flight when the last region is
/// disposed mid-gesture (e.g. opening a chat) and thrash native onListen/
/// onCancel as list rows recycle during scroll. To stop the still-installed
/// overlay from claiming a copy when nothing can accept, the active-region
/// state is pushed to native over the `ux/drop` method channel as the listener
/// set empties / fills.
class XDrop {
  XDrop._() {
    // The control channel is bidirectional — native calls back `zipProgress`
    // during a folder zip (see [startZip]).
    if (_supported) _control.setMethodCallHandler(_onControlCall);
  }

  /// Shared instance.
  static final XDrop instance = XDrop._();

  static const _events = EventChannel('ux/drop/events');

  /// Control channel shared with native. Dart→native: `setHasRegions`,
  /// `zipDirectory`, `cancelZip`. Native→Dart: `zipProgress` (the folder-zip
  /// fraction), routed by [_onControlCall].
  static const _control = MethodChannel('ux/drop');

  /// Only macOS ships a native stream handler today; elsewhere subscribing
  /// throws `MissingPluginException`, so stay inert.
  static bool get _supported => defaultTargetPlatform == TargetPlatform.macOS;

  final _listeners = <_RawListener>{};
  StreamSubscription<dynamic>? _sub;

  void _add(_RawListener listener) {
    _listeners.add(listener);
    if (_sub == null && _supported) {
      _sub = _events.receiveBroadcastStream().listen(
        _onNative,
        onError: (Object e, StackTrace st) =>
            _log.w('drop event channel error', error: e, stackTrace: st),
      );
    }
    // A region is active → the overlay (never uninstalled) should accept drops.
    // Deduped in [_setNativeHasRegions], so this is cheap to call every add.
    if (_supported) _setNativeHasRegions(true);
  }

  void _remove(_RawListener listener) {
    _listeners.remove(listener);
    // Deliberately keep the native subscription alive once created. Cancelling
    // when the set empties would (a) lose a drop that's in flight when a
    // callback — e.g. opening a chat — disposes the last region mid-gesture,
    // and (b) thrash native onListen/onCancel as ListView rows recycle during
    // scroll. Instead, when the last region detaches, tell native to report
    // `.none` so the overlay (still installed) shows no copy affordance until a
    // region re-attaches.
    if (_supported) _scheduleDisableCheck();
  }

  /// Defer the "no active regions → `.none`" signal to a microtask. A region
  /// handoff empties then refills the set within one build turn (the chat-list
  /// rows detach in the same turn the opened chat's region attaches — narrow
  /// mode dwell-to-open). Signalling `.none` synchronously would flip the
  /// overlay inert for that sub-frame and could make the OS reject a drop
  /// released right then. By the time the microtask runs, the trailing `_add`
  /// has re-filled the set, so we send nothing; only a genuine empty set (e.g.
  /// navigating to a page with no drop regions) survives to report `.none`.
  void _scheduleDisableCheck() {
    scheduleMicrotask(() {
      if (_listeners.isEmpty) _setNativeHasRegions(false);
    });
  }

  bool? _lastSentHasRegions;

  /// Push the active-region state to native (see [_control]) when it changes.
  /// Deduped so a region handoff / list scroll doesn't spam the channel;
  /// best-effort — a missing handler (non-macOS, or before the plugin
  /// registers) is swallowed.
  void _setNativeHasRegions(bool value) {
    if (_lastSentHasRegions == value) return;
    _lastSentHasRegions = value;
    unawaited(_control.invokeMethod<void>('setHasRegions', value).catchError(
      (Object e, StackTrace st) =>
          _log.w('drop setHasRegions failed', error: e, stackTrace: st),
    ));
  }

  int _zipSeq = 0;
  final _zipProgress = <String, ValueNotifier<double>>{};

  /// Start compressing a dropped directory ([dir] with [XDropFile.isDirectory])
  /// into a temp `.zip` for upload. A folder / macOS package can't be uploaded
  /// as a single file; native zips it (ZIPFoundation) off the main thread,
  /// re-acquiring access from [dir]'s security-scoped bookmark, and streams a
  /// determinate fraction back over [_control].
  ///
  /// Returns a [ZipJob]: bind a progress UI to [ZipJob.progress], `await`
  /// [ZipJob.result] for the zip as an [XDropFile] marked
  /// [XDropFile.isTemporaryCopy] (promote into the cache after upload), and call
  /// [ZipJob.cancel] to abort. `result` is null when cancelled or unsupported
  /// (non-macOS) and throws on a genuine zip failure — the caller sends nothing
  /// in either case, surfacing only the failure.
  ZipJob startZip(XDropFile dir) {
    final id = 'zip${_zipSeq++}';
    final progress = ValueNotifier<double>(0);
    _zipProgress[id] = progress;
    return ZipJob._(
      id: id,
      progress: progress,
      result: _runZip(id, dir),
      cancel: () => _cancelZip(id),
    );
  }

  Future<XDropFile?> _runZip(String id, XDropFile dir) async {
    if (!_supported) {
      _zipProgress.remove(id);
      return null;
    }
    try {
      final res = await _control.invokeMapMethod<String, Object?>(
        'zipDirectory',
        {'jobId': id, 'path': dir.path, 'bookmark': dir.bookmark},
      );
      final path = res?['path'] as String?;
      if (path == null || path.isEmpty) return null;
      return XDropFile(
        path: path,
        name: (res?['name'] as String?) ?? path.split('/').last,
        isTemporaryCopy: true,
      );
    } on PlatformException catch (e) {
      // 'cancelled' is the user aborting — expected; complete with null silently.
      if (e.code == 'cancelled') return null;
      // Genuine failure: log and rethrow so the caller can surface it (the
      // folder otherwise vanishes with nothing sent — the silent-fail trap).
      _log.w('drop zip failed', error: e);
      rethrow;
    } finally {
      // Drop the reference (the notifier is short-lived per job). Not disposed:
      // a UI still unmounting could otherwise read a disposed notifier; with no
      // listeners left it's GC'd.
      _zipProgress.remove(id);
    }
  }

  void _cancelZip(String id) {
    if (!_supported) return;
    unawaited(_control.invokeMethod<void>('cancelZip', id).catchError(
      (Object e, StackTrace st) =>
          _log.w('drop cancelZip failed', error: e, stackTrace: st),
    ));
  }

  /// Native → Dart calls on [_control]: routes `zipProgress` to the job's
  /// [ValueNotifier].
  Future<dynamic> _onControlCall(MethodCall call) async {
    if (call.method == 'zipProgress' && call.arguments is Map) {
      final m = (call.arguments as Map).cast<Object?, Object?>();
      final id = m['jobId'] as String?;
      final fraction = (m['fraction'] as num?)?.toDouble();
      if (id != null && fraction != null) {
        _zipProgress[id]?.value = fraction.clamp(0.0, 1.0);
      }
    }
    return null;
  }

  void _onNative(Object? event) {
    final raw = _parse(event);
    if (raw == null) return;
    // Snapshot, and re-check membership: a callback (push a route, rebuild the
    // list) can dispose other regions mid-dispatch, removing their listeners.
    for (final listener in _listeners.toList(growable: false)) {
      if (_listeners.contains(listener)) listener(raw);
    }
  }

  _RawEvent? _parse(Object? event) {
    if (event is! Map) return null;
    final m = event.cast<Object?, Object?>();
    final phase = switch (m['type']) {
      'enter' => _Phase.enter,
      'update' => _Phase.update,
      'exit' => _Phase.exit,
      'drop' => _Phase.drop,
      _ => null,
    };
    if (phase == null) return null;
    final x = (m['x'] as num?)?.toDouble() ?? 0;
    final y = (m['y'] as num?)?.toDouble() ?? 0;
    final files = <XDropFile>[];
    if (phase == _Phase.drop && m['items'] is List) {
      for (final item in m['items'] as List) {
        if (item is! Map) continue;
        final file = XDropFile.fromItem(item.cast<Object?, Object?>());
        if (file != null) files.add(file);
      }
    }
    return _RawEvent(phase, Offset(x, y), files);
  }
}

/// A region that accepts OS file drops.
///
/// While a drag hovers inside this region's painted bounds, [builder] is
/// invoked with `isOver: true` and [onEnter] fires; leaving fires [onExit]; a
/// drop inside fires [onPerform] with the files.
///
/// Set [enable] to `false` whenever the region is occluded by a page painted
/// in front of it: native drag events are delivered by geometry regardless of
/// paint order, so an occluded-but-enabled region would still react. Disabling
/// detaches it entirely and clears any hover.
class XDropRegion extends StatefulWidget {
  /// Creates a drop region.
  const XDropRegion({
    super.key,
    required this.builder,
    this.onPerform,
    this.onEnter,
    this.onExit,
    this.enable = true,
  });

  /// Builds the child; [isOver] is true while a drag hovers inside the bounds.
  final Widget Function(BuildContext context, bool isOver) builder;

  /// Fired with the dropped files when a drop lands inside this region.
  final ValueChanged<List<XDropFile>>? onPerform;

  /// Fired when a drag enters this region's bounds.
  final VoidCallback? onEnter;

  /// Fired when a drag leaves the bounds, or the region is disabled mid-drag.
  final VoidCallback? onExit;

  /// When false the region detaches from the drag stream and reacts to nothing.
  final bool enable;

  @override
  State<XDropRegion> createState() => _XDropRegionState();
}

class _XDropRegionState extends State<XDropRegion> {
  bool _over = false;
  bool _listening = false;
  // Whether this element is currently in the tree (active). `mounted` stays
  // true while an element is merely *deactivated* (e.g. reparented or scrolled
  // out, pending reactivation or disposal), but `findRenderObject()` throws on
  // an inactive element — so a drag event arriving in that window would crash.
  bool _inTree = true;

  @override
  void initState() {
    super.initState();
    if (widget.enable) _listen();
  }

  @override
  void activate() {
    super.activate();
    _inTree = true;
  }

  @override
  void deactivate() {
    _inTree = false;
    // Drop stale hover so a reactivated region (e.g. after a transition) starts
    // clean; a continuing drag re-evaluates on the next event. No setState —
    // reactivation rebuilds anyway, and setState is illegal during deactivate.
    _over = false;
    super.deactivate();
  }

  @override
  void didUpdateWidget(XDropRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enable && !_listening) {
      _listen();
    } else if (!widget.enable && _listening) {
      _unlisten();
      // Disabled mid-hover (e.g. the occlusion gate flips while a drag is over
      // this region): clear hover WITHOUT setState — `didUpdateWidget` runs
      // during the parent's build and `build()` follows immediately, so a
      // setState here would be an illegal "markNeedsBuild during build".
      if (_over) {
        _over = false;
        widget.onExit?.call();
      }
    }
  }

  @override
  void dispose() {
    _unlisten();
    super.dispose();
  }

  void _listen() {
    XDrop.instance._add(_onRaw);
    _listening = true;
  }

  void _unlisten() {
    if (!_listening) return;
    XDrop.instance._remove(_onRaw);
    _listening = false;
  }

  bool _contains(Offset global) {
    if (!mounted || !_inTree) return false;
    final ro = context.findRenderObject();
    if (ro is! RenderBox || !ro.attached || !ro.hasSize) return false;
    // Layout bounds (Offset.zero & size), not paintBounds — the latter can
    // extend past the layout rect for boxes that paint outside themselves.
    return (Offset.zero & ro.size).contains(ro.globalToLocal(global));
  }

  void _onRaw(_RawEvent event) {
    if (!mounted || !_inTree) return;
    switch (event.phase) {
      case _Phase.enter:
      case _Phase.update:
        _setOver(_contains(event.position));
      case _Phase.exit:
        _clearOver(notify: true);
      case _Phase.drop:
        final inside = _contains(event.position);
        _clearOver(notify: false);
        if (inside) widget.onPerform?.call(event.files);
    }
  }

  void _setOver(bool value) {
    if (_over == value) return;
    _over = value;
    if (mounted) setState(() {});
    if (value) {
      widget.onEnter?.call();
    } else {
      widget.onExit?.call();
    }
  }

  void _clearOver({required bool notify}) {
    if (!_over) return;
    _over = false;
    if (mounted) setState(() {});
    if (notify) widget.onExit?.call();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _over);
}
