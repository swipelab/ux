import 'package:flutter/foundation.dart'
    show ValueListenable, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';

import '../core/emitter.dart';
import '../log.dart' show Log;

final _log = Log.tag('window');

/// Host-window state primitive: [focused] state plus the [keepAwake] screen
/// hold. Future window-level state — minimized, occluded, screen — can land
/// alongside them without disturbing call sites.
abstract interface class XWindow {
  /// The process-wide platform window.
  static final XWindow instance = MethodChannelXWindow();

  /// `true` when this app currently has user focus.
  ///
  /// - macOS: tracks `NSApplication` active / resign via the native plugin.
  /// - Android: tracks app foreground / background via `ProcessLifecycleOwner`,
  ///   so a backgrounded-but-alive process reports `false`.
  /// - Windows: tracks `WM_ACTIVATEAPP` on the app's window, so a minimized
  ///   window or another app in front reports `false`.
  /// - iOS: the native plugin serves [keepAwake] only, so the emitter stays
  ///   at its `true` default.
  ValueListenable<bool> get focused;

  /// Holds the screen awake while [enabled], for a call or another session
  /// the user watches without touching the device. Idempotent.
  ///
  /// iOS disables the idle timer, Android sets `FLAG_KEEP_SCREEN_ON` on the
  /// activity window, macOS takes an `IOPMAssertion` against display sleep,
  /// Windows sets `ES_DISPLAY_REQUIRED` with `SetThreadExecutionState`.
  /// No hold outlives the app that took it: Android drops it when the
  /// activity or the engine detaches, iOS while the app is out of the
  /// foreground, macOS on termination, Windows when the window is destroyed,
  /// and every platform when the process dies.
  Future<void> keepAwake(bool enabled);
}

/// Production [XWindow], over the `ux/window` channels.
class MethodChannelXWindow implements XWindow {
  /// Subscribes to the native event channel where one is registered.
  MethodChannelXWindow() {
    if (!_hasNativeHandler) return;
    _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: (e, st) {
        _log.w('event channel error', error: e, stackTrace: st);
      },
    );
  }

  /// Only macOS, Android and Windows register a native stream handler for the
  /// events channel; activating it elsewhere throws `MissingPluginException`.
  static bool get _hasNativeHandler =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.windows;

  static bool get _hasKeepAwake =>
      _hasNativeHandler || defaultTargetPlatform == TargetPlatform.iOS;

  static const _events = EventChannel('ux/window/events');
  static const _methods = MethodChannel('ux/window');

  @override
  final ValueEmitter<bool> focused = ValueEmitter(true);

  @override
  Future<void> keepAwake(bool enabled) async {
    if (!_hasKeepAwake) return;
    try {
      await _methods.invokeMethod<void>('keepAwake', {'enabled': enabled});
    } on PlatformException catch (e, st) {
      _log.w('keepAwake($enabled) failed', error: e, stackTrace: st);
    }
  }

  void _onEvent(Object? event) {
    if (event is! Map) return;
    final m = event.cast<Object?, Object?>();
    if (m['type'] == 'focus') {
      final f = m['focused'];
      if (f is! bool) return;
      _log.i('focused: $f');
      focused.value = f;
    }
  }
}
