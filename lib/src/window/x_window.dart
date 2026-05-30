import 'package:flutter/foundation.dart'
    show ValueListenable, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';

import '../core/emitter.dart';
import '../log.dart' show Log;

final _log = Log.tag('window');

/// Host-window state primitive. Today exposes only [focused] (the macOS
/// `NSApp.didBecomeActive` / `didResignActive` signal); future window-level
/// state — minimized, occluded, screen — can land alongside it without
/// disturbing call sites.
abstract interface class XWindow {
  static final XWindow instance = MethodChannelXWindow();

  /// `true` when this app currently has user focus.
  ///
  /// - macOS: tracks `NSApplication` active / resign via the native plugin.
  /// - Android: tracks app foreground / background via `ProcessLifecycleOwner`,
  ///   so a backgrounded-but-alive process reports `false`.
  /// - iOS: no native plugin registers, so the emitter stays at its `true`
  ///   default.
  ValueListenable<bool> get focused;
}

class MethodChannelXWindow implements XWindow {
  MethodChannelXWindow() {
    if (!_hasNativeHandler) return;
    _events.receiveBroadcastStream().listen(_onEvent, onError: (e, st) {
      _log.w('event channel error', error: e, stackTrace: st);
    });
  }

  /// Only macOS and Android register a native stream handler for the events
  /// channel; activating it elsewhere throws `MissingPluginException`.
  static bool get _hasNativeHandler =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.android;

  static const _events = EventChannel('ux/window/events');

  @override
  final ValueEmitter<bool> focused = ValueEmitter(true);

  void _onEvent(Object? event) {
    if (event is! Map) return;
    final m = event.cast<Object?, Object?>();
    if (m['type'] == 'focus') {
      final f = m['focused'];
      if (f is bool) focused.value = f;
    }
  }
}
